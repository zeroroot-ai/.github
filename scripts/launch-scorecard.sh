#!/usr/bin/env bash
#
# launch-scorecard.sh — measure outcomes, not activity.
#
# Two stages, deliberately separated so the renderer is testable without network:
#
#   collect  → writes a JSON document of measured facts to stdout
#   render   → reads that JSON on stdin, writes the issue body to stdout
#   publish  → upserts the pinned LAUNCH SCORECARD issue with that body
#
# Usage:
#   scripts/launch-scorecard.sh collect > /tmp/sc.json
#   scripts/launch-scorecard.sh render  < /tmp/sc.json > /tmp/sc.md
#   scripts/launch-scorecard.sh publish < /tmp/sc.md
#   scripts/launch-scorecard.sh all                       # collect | render | publish
#
# Why an issue and not a Project board: an agent must read the whole scorecard in
# ONE cheap command at session start. `gh issue view --json body` is one call and
# needs no GraphQL. A Project v2 board needs GraphQL to read, cannot hold a time
# series, and measures item state — which is the metric that failed us.
#
# WHY THIS EXISTS — 2026-08-13..17: the fleet merged ~570 commits, filed 455
# issues and closed 425. Zero chains passed an exit test. Closed issues measured
# activity. Nothing measured outcome. This file measures outcome.

set -euo pipefail

ORG="${ORG:-zeroroot-ai}"
SCORECARD_REPO="${SCORECARD_REPO:-${ORG}/.github}"
TITLE="${TITLE:-LAUNCH SCORECARD}"
CHAINS_FILE="${CHAINS_FILE:-data/launch-chains.tsv}"
WINDOW_DAYS="${WINDOW_DAYS:-7}"
HISTORY_KEEP="${HISTORY_KEEP:-14}"

# --- Thresholds. Breaching one produces a directive the agent must obey. -------
MAX_ISSUES_FILED="${MAX_ISSUES_FILED:-35}"      # per 7 days, whole org
MAX_HYGIENE_SHARE="${MAX_HYGIENE_SHARE:-20}"    # percent of merged PRs
MAX_REWORK_SHARE="${MAX_REWORK_SHARE:-10}"      # percent of merged PRs
MAX_OPEN_PRS="${MAX_OPEN_PRS:-3}"               # per repo
MAX_ALERT_ISSUES="${MAX_ALERT_ISSUES:-5}"       # open issues titled ci(codeql)
STALL_DAYS="${STALL_DAYS:-2}"                   # days with no chain flip = halt

die() { echo "::error::$*" >&2; exit 1; }

# search_count <query> — one search API call, returns total_count.
search_count() {
  gh api -X GET search/issues -f q="$1" -f per_page=1 --jq '.total_count' 2>/dev/null || echo 0
}

# ---------------------------------------------------------------- collect ----
collect() {
  command -v gh >/dev/null || die "gh is not installed"
  local since since_iso
  since=$(date -u -d "${WINDOW_DAYS} days ago" +%Y-%m-%d)
  since_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Blind-spot guard, copied from failure-mode-aggregator.yml: the default
  # GITHUB_TOKEN sees PUBLIC repos only. `gitops` is private and long-lived. If
  # it is invisible, every private-repo number below is silently wrong — and a
  # silently wrong scorecard is worse than no scorecard.
  if ! gh api "orgs/${ORG}/repos" --paginate --jq '.[].name' 2>/dev/null | grep -qx 'gitops'; then
    die "cannot see private repos (gitops absent) — set GH_PAT_PLATFORM_RO; a partial scorecard is not allowed"
  fi

  # --- Outcomes: the conclusion of each chain's exit-test workflow ------------
  local chains_json="[]" green=0
  while IFS=$'\t' read -r n name repo wf root exit_test; do
    [ -z "${n:-}" ] && continue
    case "$n" in \#*) continue ;; esac

    local status="NOT_BUILT" last="" url="" concl=""
    local run
    run=$(gh run list -R "${ORG}/${repo}" --workflow "$wf" --branch main --limit 1 \
            --json conclusion,createdAt,url --jq '.[0] // empty' 2>/dev/null || true)
    if [ -n "$run" ]; then
      concl=$(jq -r '.conclusion // ""' <<<"$run")
      last=$(jq -r '.createdAt // ""' <<<"$run")
      url=$(jq -r '.url // ""' <<<"$run")
      case "$concl" in
        success) status="PASS"; green=$((green + 1)) ;;
        "")      status="RUNNING" ;;
        *)       status="FAIL" ;;
      esac
    fi

    chains_json=$(jq --argjson c "$chains_json" \
      --arg n "$n" --arg name "$name" --arg repo "$repo" --arg wf "$wf" \
      --arg root "$root" --arg et "$exit_test" --arg st "$status" \
      --arg last "$last" --arg url "$url" \
      -n '$c + [{n:($n|tonumber),name:$name,repo:$repo,workflow:$wf,root:$root,
                 exit_test:$et,status:$st,last_run:$last,url:$url}]')
  done < "$CHAINS_FILE"

  # --- Behaviour: what the fleet actually did in the window ------------------
  local filed closed merged rework alerts hygiene=0 q
  filed=$(search_count "org:${ORG} is:issue created:>=${since}")
  closed=$(search_count "org:${ORG} is:issue closed:>=${since}")
  merged=$(search_count "org:${ORG} is:pr is:merged merged:>=${since}")
  rework=$(search_count "org:${ORG} is:pr is:merged merged:>=${since} in:title \"fix(rework)\"")
  alerts=$(search_count "org:${ORG} is:issue is:open in:title \"ci(codeql)\"")

  # Hygiene PRs, by Conventional-Commit scope. These are the PRs that consumed
  # the window without moving an exit test.
  for q in 'in:title "ci("' 'in:title "chore(ci"' 'in:title "chore(guards"' \
           'in:title "chore(deps"' 'in:title "fix(ci"' 'in:title "fix(guard"' \
           'in:title "fix(lint"' 'in:title "chore(security"'; do
    hygiene=$((hygiene + $(search_count "org:${ORG} is:pr is:merged merged:>=${since} ${q}")))
    sleep 2   # search API is 30 req/min
  done

  # --- Open PR load per chain-owning repo ------------------------------------
  local openprs="{}" r
  for r in $(cut -f3 "$CHAINS_FILE" | grep -v '^#' | grep -v '^$' | sort -u); do
    local c
    c=$(gh pr list -R "${ORG}/${r}" --state open --limit 100 --json number --jq 'length' 2>/dev/null || echo 0)
    openprs=$(jq --argjson o "$openprs" --arg k "$r" --argjson v "${c:-0}" -n '$o + {($k):$v}')
  done

  jq -n --arg gen "$since_iso" --arg since "$since" --argjson wd "$WINDOW_DAYS" \
        --argjson chains "$chains_json" --argjson green "$green" \
        --argjson filed "${filed:-0}" --argjson closed "${closed:-0}" \
        --argjson merged "${merged:-0}" --argjson hygiene "${hygiene:-0}" \
        --argjson rework "${rework:-0}" --argjson alerts "${alerts:-0}" \
        --argjson openprs "$openprs" \
    '{generated_at:$gen, window_since:$since, window_days:$wd,
      chains:$chains, chains_green:$green, chains_total:($chains|length),
      process:{issues_filed:$filed, issues_closed:$closed, prs_merged:$merged,
               hygiene_prs:$hygiene, rework_prs:$rework,
               alert_issues_open:$alerts, open_prs:$openprs}}'
}

# ----------------------------------------------------------------- render ----
# Reads the collect JSON on stdin. Also reads the CURRENT issue body from
# $PREV_BODY (a file) when present, so the history block survives a rewrite.
render() {
  local j; j=$(cat)
  local gen since green total filed closed merged hygiene rework alerts
  gen=$(jq -r '.generated_at' <<<"$j")
  since=$(jq -r '.window_since' <<<"$j")
  green=$(jq -r '.chains_green' <<<"$j")
  total=$(jq -r '.chains_total' <<<"$j")
  filed=$(jq -r '.process.issues_filed' <<<"$j")
  closed=$(jq -r '.process.issues_closed' <<<"$j")
  merged=$(jq -r '.process.prs_merged' <<<"$j")
  hygiene=$(jq -r '.process.hygiene_prs' <<<"$j")
  rework=$(jq -r '.process.rework_prs' <<<"$j")
  alerts=$(jq -r '.process.alert_issues_open' <<<"$j")

  local hyg_share=0 rew_share=0
  [ "$merged" -gt 0 ] && hyg_share=$(( hygiene * 100 / merged ))
  [ "$merged" -gt 0 ] && rew_share=$(( rework * 100 / merged ))

  # History: previous lines are "YYYY-MM-DD green=N filed=N merged=N".
  local prev_hist="" prev_green="" stall_days=0
  if [ -n "${PREV_BODY:-}" ] && [ -f "${PREV_BODY}" ]; then
    prev_hist=$(sed -n '/<!--history-->/,/<!--\/history-->/p' "$PREV_BODY" \
                | grep -E '^- [0-9]{4}-' || true)
    # Count leading days at the same green count = the stall length.
    prev_green=$(head -1 <<<"$prev_hist" | grep -oE 'green=[0-9]+' | cut -d= -f2 || true)
    while read -r line; do
      [ -z "$line" ] && continue
      local g; g=$(grep -oE 'green=[0-9]+' <<<"$line" | cut -d= -f2)
      [ "$g" = "$green" ] || break
      stall_days=$((stall_days + 1))
    done <<<"$prev_hist"
  fi

  local today; today=$(date -u -d "$gen" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)
  local hist_new="- ${today} green=${green} filed=${filed} merged=${merged} hygiene=${hyg_share}%"
  local history; history=$(printf '%s\n%s\n' "$hist_new" "$prev_hist" \
                            | grep -E '^- [0-9]{4}-' | head -"$HISTORY_KEEP")

  # --- Directives. These are orders, not observations. -----------------------
  local directives=() verdict="GREEN"
  if [ "$green" -lt "$total" ]; then verdict="RED"; fi

  local first_red
  first_red=$(jq -r '[.chains[] | select(.status != "PASS")] | sort_by(.n) | .[0].n // empty' <<<"$j")
  local first_red_name
  first_red_name=$(jq -r --arg n "$first_red" '.chains[] | select((.n|tostring)==$n) | .name' <<<"$j" 2>/dev/null || true)

  if [ -n "$first_red" ]; then
    directives+=("**Work chain ${first_red} (${first_red_name}) only.** It is the lowest-numbered chain that is not PASS. Do not start another chain, and do not open work outside it.")
  fi
  if jq -e '[.chains[] | select(.status=="NOT_BUILT")] | length > 0' <<<"$j" >/dev/null; then
    local nb; nb=$(jq -r '[.chains[]|select(.status=="NOT_BUILT")|.n]|join(", ")' <<<"$j")
    directives+=("**Chains ${nb} have no exit-test workflow.** An exit test nothing can run is not an exit test. Building the workflow IS the first task of that chain. It must run without staging or prod.")
  fi
  if [ "$stall_days" -ge "$STALL_DAYS" ]; then
    directives+=("**STALL: ${stall_days} days with no chain flip. HALT.** Do not start new work. Post the halt banner. State in one sentence what is actually blocking chain ${first_red}, and what decision or access you need. Volume is not progress.")
    verdict="STALLED"
  fi
  if [ "$filed" -gt "$MAX_ISSUES_FILED" ]; then
    directives+=("**Issue filing is over budget (${filed} in ${WINDOW_DAYS} days, limit ${MAX_ISSUES_FILED}). File nothing this session.** Findings go in the PR body.")
  fi
  if [ "$alerts" -gt "$MAX_ALERT_ISSUES" ]; then
    directives+=("**The tracker is being used as an alert queue (${alerts} open \`ci(codeql)\` issues, limit ${MAX_ALERT_ISSUES}).** Close them as superseded. Scanner output belongs in the Security tab and in ONE standing issue per repo. Never one issue per rule or per CVE.")
  fi
  if [ "$hyg_share" -gt "$MAX_HYGIENE_SHARE" ]; then
    directives+=("**Hygiene work is ${hyg_share}% of merged PRs (limit ${MAX_HYGIENE_SHARE}%).** Your next PR must touch product paths — \`helm/\`, \`terraform/\`, \`internal/\`, \`operators/\`, \`app/\`, \`src/\` — not \`.github/\` or \`scripts/\`.")
  fi
  if [ "$rew_share" -gt "$MAX_REWORK_SHARE" ]; then
    directives+=("**Rework is ${rew_share}% of merged PRs (limit ${MAX_REWORK_SHARE}%).** Stop. Write the root cause into the chain issue before you write more code. A guard that needs re-pinning is a defect in the guard.")
  fi
  local r c
  for r in $(jq -r '.process.open_prs | keys[]' <<<"$j"); do
    c=$(jq -r --arg r "$r" '.process.open_prs[$r]' <<<"$j")
    if [ "$c" -ge "$MAX_OPEN_PRS" ]; then
      directives+=("**\`${r}\` has ${c} open PRs (limit ${MAX_OPEN_PRS}).** Land one before you open another.")
    fi
  done
  [ ${#directives[@]} -eq 0 ] && directives+=("No rule is breached. Work your chain.")

  # --- Body ------------------------------------------------------------------
  local badge="🔴 RED"
  [ "$verdict" = "GREEN" ] && badge="🟢 GREEN"
  [ "$verdict" = "STALLED" ] && badge="🛑 STALLED"

  cat <<EOF
<!-- Generated by scripts/launch-scorecard.sh. Do not hand-edit: the next run overwrites it. -->

# ${badge} — ${green} of ${total} chains passing

Generated ${gen}. Window: last ${WINDOW_DAYS} days (since ${since}).

## AGENT DIRECTIVES — read before you start work

These override CLAUDE.md priorities. Apply them, then work.

$(printf '%s\n' "${directives[@]}" | sed 's/^/1. /')

## Outcomes — the only measure of progress

| # | Chain | Status | Exit test | Last run |
|---|---|---|---|---|
$(jq -r '.chains[] | "| \(.n) | \(.name) (\(.root)) | **\(.status)** | \(.exit_test) | \(if .url != "" then "[\(.last_run[0:10])](\(.url))" else "never" end) |"' <<<"$j")

\`PASS\` means the named workflow's latest run on \`main\` succeeded. Nothing else
is done: not merged, not closed, not "waiting on bringup".

## Behaviour — is the fleet spending effort on outcomes?

| Metric | Value | Limit | |
|---|---|---|---|
| Issues filed | ${filed} | ${MAX_ISSUES_FILED} | $([ "$filed" -gt "$MAX_ISSUES_FILED" ] && echo "❌" || echo "✅") |
| Issues closed | ${closed} | — | |
| PRs merged | ${merged} | — | |
| Hygiene share | ${hyg_share}% | ${MAX_HYGIENE_SHARE}% | $([ "$hyg_share" -gt "$MAX_HYGIENE_SHARE" ] && echo "❌" || echo "✅") |
| Rework share | ${rew_share}% | ${MAX_REWORK_SHARE}% | $([ "$rew_share" -gt "$MAX_REWORK_SHARE" ] && echo "❌" || echo "✅") |
| Open \`ci(codeql)\` issues | ${alerts} | ${MAX_ALERT_ISSUES} | $([ "$alerts" -gt "$MAX_ALERT_ISSUES" ] && echo "❌" || echo "✅") |
| Open PRs per repo | $(jq -r '.process.open_prs | to_entries | map("\(.key)=\(.value)") | join(", ")' <<<"$j") | ${MAX_OPEN_PRS} | |

A high closed-issue count with zero chain flips is the failure signature of
2026-08-13..17. Treat it as a red flag, never as progress.

## Trend

<!--history-->
${history}
<!--/history-->

## Machine-readable

<!--scorecard-json-->
\`\`\`json
${j}
\`\`\`
<!--/scorecard-json-->
EOF
}

# ---------------------------------------------------------------- publish ----
publish() {
  local body_file; body_file=$(mktemp)
  cat > "$body_file"

  local num
  num=$(gh issue list -R "$SCORECARD_REPO" --state open --limit 1 \
          --search "in:title \"${TITLE}\"" --json number --jq '.[0].number // empty')

  if [ -z "$num" ]; then
    num=$(gh issue create -R "$SCORECARD_REPO" --title "$TITLE" \
            --body-file "$body_file" --label "scorecard" 2>/dev/null \
          || gh issue create -R "$SCORECARD_REPO" --title "$TITLE" --body-file "$body_file")
    num=$(grep -oE '[0-9]+$' <<<"$num")
    echo "created ${SCORECARD_REPO}#${num}"
    # Pin it: agents are told to search by title, but a pinned issue is what the
    # human sees first when they open the tracker.
    local id
    id=$(gh issue view "$num" -R "$SCORECARD_REPO" --json id --jq .id)
    gh api graphql -f query='mutation($id:ID!){pinIssue(input:{issueId:$id}){issue{number}}}' \
      -f id="$id" >/dev/null 2>&1 || echo "::warning::could not pin — pin it by hand"
  else
    gh issue edit "$num" -R "$SCORECARD_REPO" --body-file "$body_file" >/dev/null
    echo "updated ${SCORECARD_REPO}#${num}"
  fi
  rm -f "$body_file"
}

# --- Fetch the current body so render() can carry the history forward --------
prev_body_file() {
  local f; f=$(mktemp)
  gh issue list -R "$SCORECARD_REPO" --state open --limit 1 \
    --search "in:title \"${TITLE}\"" --json body --jq '.[0].body // ""' > "$f" 2>/dev/null || true
  echo "$f"
}

case "${1:-all}" in
  collect) collect ;;
  render)  render ;;
  publish) publish ;;
  all)
    PREV_BODY=$(prev_body_file); export PREV_BODY
    collect | render | publish
    rm -f "$PREV_BODY"
    ;;
  *) die "usage: $0 {collect|render|publish|all}" ;;
esac
