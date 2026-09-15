#!/usr/bin/env bash
#
# test-launch-scorecard.sh — the renderer must show the RIGHT STATE. It reports
# measured facts and gives no orders. A scorecard that cannot go red is worse
# than no scorecard, so a bad fixture must render RED and mark every breached
# metric — but it must never emit a directive telling an agent to halt or stop.
#
# No network. Feeds crafted JSON to `launch-scorecard.sh render`.

set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT=scripts/launch-scorecard.sh
PASS=0 FAIL=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

assert_has()  { if grep -qF -- "$2" "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: expected to find: $2"; fi; }
assert_lacks() { if grep -qF -- "$2" "$1"; then FAIL=$((FAIL+1)); echo "  FAIL: did not expect: $2"; else PASS=$((PASS+1)); fi; }

blocker() { # n name status
  jq -n --argjson n "$1" --arg name "$2" --arg st "$3" \
    '{n:$n,name:$name,repo:"deploy",workflow:"w.yml",root:"deploy#1",
      plain:"plain english for a human",exit_test:"t",status:$st,
      last_run:"2026-08-17T00:00:00Z",url:""}'
}

mkfixture() { # status filed hygiene merged rework alerts openprs
  jq -n \
    --argjson blockers "$(jq -s . <<<"$(blocker 1 One "$1"; blocker 2 Two NOT_BUILT)")" \
    --argjson filed "$2" --argjson hygiene "$3" --argjson merged "$4" \
    --argjson rework "$5" --argjson alerts "$6" --argjson openprs "$7" \
    --argjson signals "$(jq -s . <<<"$(blocker '"S1"' "Edge WAF" NOT_BUILT)")" \
    '{generated_at:"2026-08-17T06:00:00Z", window_since:"2026-08-10", window_days:7,
      blockers:$blockers, green:(if $blockers[0].status=="PASS" then 1 else 0 end),
      total:2, signals:$signals,
      process:{issues_filed:$filed, issues_closed:0, prs_merged:$merged,
               hygiene_prs:$hygiene, rework_prs:$rework, alert_issues_open:$alerts,
               open_prs:$openprs}}'
}

# The exact strings of the retired directive machinery. None may ever render.
NO_ORDERS=(
  "AGENT DIRECTIVES" "HALT" "STALLED" "Work blocker" "File nothing this session"
  "No rule is breached" "override CLAUDE.md" "Post the halt banner" "stop the turn"
)
assert_no_orders() { local f; for f in "${NO_ORDERS[@]}"; do assert_lacks "$1" "$f"; done; }

echo "== everything bad: renders RED state and marks every breach, but gives NO orders =="
mkfixture FAIL 800 40 100 20 193 '{"deploy":7}' > "$tmp/bad.json"
cat > "$tmp/prev.md" <<'EOF'
<!--history-->
- 2026-08-16 green=0 filed=700 merged=90 hygiene=30%
- 2026-08-15 green=0 filed=600 merged=80 hygiene=30%
- 2026-08-14 green=0 filed=500 merged=70 hygiene=30%
<!--/history-->
EOF
PREV_BODY="$tmp/prev.md" "$SCRIPT" render < "$tmp/bad.json" > "$tmp/bad.md"

assert_has  "$tmp/bad.md" "RED"
assert_has  "$tmp/bad.md" "NOT_BUILT"
# The board must always say what a blocker MEANS, not only how it is proved.
assert_has  "$tmp/bad.md" "plain english for a human"
assert_has  "$tmp/bad.md" "What it means"
# A breached metric still surfaces, with a ❌ marker — as an observation.
assert_has  "$tmp/bad.md" "❌"
assert_has  "$tmp/bad.md" "40%"
assert_has  "$tmp/bad.md" "20%"
# History carries forward, not reset.
assert_has  "$tmp/bad.md" "- 2026-08-14 green=0"
# Other launch signals render in their own table and never count in the verdict
# (.github#301): two blockers, one failing, one signal NOT_BUILT -> still "0 of 2".
assert_has  "$tmp/bad.md" "## Other launch signals"
assert_has  "$tmp/bad.md" "| S1 | Edge WAF (deploy#1) | **NOT_BUILT** |"
assert_has  "$tmp/bad.md" "0 of 2 blockers passing"
assert_no_orders "$tmp/bad.md"

echo "== everything good: GREEN, still no orders =="
mkfixture PASS 4 1 40 0 0 '{"deploy":1}' > "$tmp/ok.json"
jq '.blockers[1].status="PASS" | .green=2' "$tmp/ok.json" > "$tmp/ok2.json"
"$SCRIPT" render < "$tmp/ok2.json" > "$tmp/ok.md"
assert_has  "$tmp/ok.md" "GREEN"
# A NOT_BUILT signal does not stop the verdict being GREEN.
assert_has  "$tmp/ok.md" "2 of 2 blockers passing"
assert_has  "$tmp/ok.md" "| S1 | Edge WAF (deploy#1) | **NOT_BUILT** |"
assert_no_orders "$tmp/ok.md"

echo "== re-runs on one day are one history line =="
cat > "$tmp/prev-dupes.md" <<'EOF'
<!--history-->
- 2026-08-17 green=0 filed=581 merged=594 hygiene=40%
- 2026-08-17 green=0 filed=580 merged=593 hygiene=40%
- 2026-08-16 green=0 filed=500 merged=500 hygiene=40%
<!--/history-->
EOF
PREV_BODY="$tmp/prev-dupes.md" "$SCRIPT" render < "$tmp/bad.json" > "$tmp/dupes.md"
hist_today=$(sed -n '/<!--history-->/,/<!--\/history-->/p' "$tmp/dupes.md" | grep -c '^- 2026-08-17 ')
if [ "$hist_today" -eq 1 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: today appears $hist_today times in history, expected 1"; fi
assert_has "$tmp/dupes.md" "- 2026-08-16 green=0"

echo "== a SKIPPED signal renders as SKIPPED and never counts as green =="
# A run gated off by a missing repository secret tested nothing. It must not
# read PASS on the board, and it must not change the verdict either way.
mkfixture PASS 4 1 40 0 0 '{"deploy":1}' > "$tmp/skip.json"
jq '.blockers[1].status="PASS" | .green=2
    | .signals=[{n:"S3",name:"Bank of always-on agents",repo:"gibson",
                 workflow:"exit-test-bank.yml",root:"gibson#1706",
                 plain:"a bank of two takes one job",exit_test:"t",
                 status:"SKIPPED",last_run:"2026-09-02T00:00:00Z",url:""}]' \
  "$tmp/skip.json" > "$tmp/skip2.json"
"$SCRIPT" render < "$tmp/skip2.json" > "$tmp/skip.md"
assert_has  "$tmp/skip.md" "| S3 | Bank of always-on agents (gibson#1706) | **SKIPPED** |"
assert_has  "$tmp/skip.md" "2 of 2 blockers passing"
assert_lacks "$tmp/skip.md" "| S3 | Bank of always-on agents (gibson#1706) | **PASS** |"
assert_no_orders "$tmp/skip.md"

echo "== behaviour markers track the alert limit as a boundary =="
# 5 == limit and nothing else breached → all ✅, no ❌.
mkfixture PASS 4 1 40 0 5 '{"deploy":1}' > "$tmp/a5.json"
"$SCRIPT" render < "$tmp/a5.json" > "$tmp/a5.md"
assert_lacks "$tmp/a5.md" "❌"
# 6 > limit → the alert row marks ❌.
mkfixture PASS 4 1 40 0 6 '{"deploy":1}' > "$tmp/a6.json"
"$SCRIPT" render < "$tmp/a6.json" > "$tmp/a6.md"
assert_has "$tmp/a6.md" "❌"

echo "== a deleted workflow is NOT_BUILT, however its last run concluded =="
# THE FIXTURE THIS GUARD EXISTS FOR. GitHub keeps a renamed or deleted workflow
# addressable by its old filename and still serves its run history, so
# `gh run list --workflow <gone>.yml` answers with the last run it ever had.
# On 2026-09-15 exit-test-vanilla-install became exit-test-baseline-install
# while its last run was green, and the S1 row read PASS against a file that no
# longer existed. Nothing would ever have moved it off green again.
#
# Drive `measure` with a stubbed `gh` so this needs no network. Each row names
# a workflow the stub answers for.
stub=$tmp/bin; mkdir -p "$stub"
cat > "$stub/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal `gh` for the measure fixtures. Answers on the workflow FILENAME.
wf=""
for a in "$@"; do case "$a" in *.yml) wf=${a##*/} ;; esac; done
case "$1" in
  api)
    # `gh api repos/<org>/<repo>/actions/workflows/<wf> --jq .state`
    case "$wf" in
      gone.yml)    echo deleted ;;
      missing.yml) exit 1 ;;   # 404: gh exits non-zero and prints nothing
      *)           echo active ;;
    esac
    ;;
  run)
    # `gh run list ... --jq '.[0] // empty'` — every one of these has history.
    case "$wf" in
      skipped.yml) echo '{"conclusion":"skipped","createdAt":"2026-09-15T00:00:00Z","url":"u"}' ;;
      *)           echo '{"conclusion":"success","createdAt":"2026-09-15T00:00:00Z","url":"u"}' ;;
    esac
    ;;
esac
STUB
chmod +x "$stub/gh"

printf 'A\tActive\thosted\tlive.yml\t—\tp\te\n'    > "$tmp/rows.tsv"
printf 'B\tRenamed\thosted\tgone.yml\t—\tp\te\n'   >> "$tmp/rows.tsv"
printf 'C\tAbsent\thosted\tmissing.yml\t—\tp\te\n' >> "$tmp/rows.tsv"
printf 'D\tGated\thosted\tskipped.yml\t—\tp\te\n'  >> "$tmp/rows.tsv"

PATH="$stub:$PATH" "$SCRIPT" measure "$tmp/rows.tsv" > "$tmp/rows.json"

want() { # workflow expected-status
  local got; got=$(jq -r --arg w "$1" '.[] | select(.workflow==$w) | .status' "$tmp/rows.json")
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $1 measured $got, expected $2"; fi
}
# An active workflow still measures its latest run. The guard must not break it.
want live.yml    PASS
# Deleted, but its history is green. The board must not carry that green.
want gone.yml    NOT_BUILT
# Never existed, or the repo is unreadable. Same answer.
want missing.yml NOT_BUILT
# The gated-off run keeps reading SKIPPED.
want skipped.yml SKIPPED

echo "== every row of every shipped TSV names a workflow that exists =="
# The S1 row pointed at a deleted workflow for hours before anyone noticed.
# This asserts the shape of the table, offline: a workflow column must look
# like a workflow file, so a row can never name a directory or a bare word.
for f in data/launch-blockers.tsv data/launch-signals.tsv; do
  bad=$(awk -F'\t' '!/^#/ && NF>3 && $4 !~ /^[a-z0-9-]+\.yml$/ {print $1": "$4}' "$f")
  if [ -z "$bad" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $f has a bad workflow column: $bad"; fi
done

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
