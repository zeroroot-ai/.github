#!/usr/bin/env bash
# Org-wide code-scanning (SARIF) triage — ONE digest issue per repo.
#
# Called by .github/workflows/sarif-triage.yml. Behavior contract
# (regression-tested by scripts/test-sarif-triage.sh — keep them in sync):
#
#   * One digest issue per repo, never one per rule (.github#252 incident:
#     the first successful run of the old per-rule filer created ~200
#     issues org-wide). The digest is found by the stable title prefix
#     and updated in place — the same pattern as the flake-report
#     aggregator in this repo.
#   * Repos with ZERO open code-scanning alerts are skipped entirely.
#   * "API said no alerts" is distinguished from "API errored". An API
#     error (or any non-array response body) is NEVER parsed as alerts —
#     it is surfaced in the run log and turns the run red at the end,
#     never filed as an issue. (The old code parsed the error body as one
#     alert with null fields → the `rule null` junk issues.)
#   * Severity floor: only error-severity rules are listed in detail;
#     warning/note alerts roll up into the counts line. The digest links
#     the repo's code-scanning UI for the full list.
#   * Size cap: at most MAX_RULE_ROWS detail rows; if the rendered body
#     still exceeds MAX_BODY_BYTES it collapses to counts + link.
#   * Hard safety: if a run would ever create MORE than one NEW issue in
#     the same repo, it aborts the whole run loudly instead.
#
# Requires: gh (authenticated via GH_TOKEN), jq.

set -euo pipefail

ORG="${SARIF_TRIAGE_ORG:-zeroroot-ai}"
TITLE_PREFIX="ci(codeql): code-scanning digest"
MAX_RULE_ROWS="${SARIF_TRIAGE_MAX_RULE_ROWS:-25}"
MAX_BODY_BYTES="${SARIF_TRIAGE_MAX_BODY_BYTES:-20000}"

# fetch_alerts return codes (besides 0 = ok, alerts written as one JSON array)
RC_SKIP=10   # repo has no code scanning (404 / not enabled) — skip, not an error
RC_ERR=20    # API error or malformed response — log it, never file it

# Tracks NEW issues created per repo this run (hard-safety invariant).
declare -A CREATED_PER_REPO

# ---------------------------------------------------------------------------
# fetch_alerts <repo> <out_file>
# Writes the repo's open code-scanning alerts to <out_file> as ONE JSON array.
fetch_alerts() {
  local repo="$1" out="$2"
  local raw err rc=0
  raw=$(mktemp) err=$(mktemp)
  gh api "/repos/${ORG}/${repo}/code-scanning/alerts?state=open&per_page=100" \
    --paginate >"$raw" 2>"$err" || rc=$?

  if [ "$rc" -ne 0 ]; then
    if grep -qiE 'HTTP 404|no analysis found|code scanning is not enabled|not set ?up|advanced security' "$err"; then
      rm -f "$raw" "$err"
      return "$RC_SKIP"
    fi
    sed 's/^/  api stderr: /' "$err" >&2
    rm -f "$raw" "$err"
    return "$RC_ERR"
  fi

  # gh --paginate emits one JSON document per page. Accept ONLY a non-empty
  # stream where every page is an array — an error object, an empty body, or
  # any other shape must never be treated as alert data.
  if ! jq -es 'length > 0 and all(type == "array")' "$raw" >/dev/null 2>&1; then
    echo "unexpected response shape from the code-scanning API for ${ORG}/${repo} (not a JSON array)" >&2
    rm -f "$raw" "$err"
    return "$RC_ERR"
  fi

  jq -s 'add' "$raw" > "$out"
  rm -f "$raw" "$err"
  return 0
}

# ---------------------------------------------------------------------------
# build_digest <repo> <alerts_file>   (pure: alerts JSON array -> markdown)
build_digest() {
  local repo="$1" alerts="$2"
  local total errors warnings other day link
  total=$(jq 'length' "$alerts")
  errors=$(jq '[.[] | select(.rule.severity == "error")] | length' "$alerts")
  warnings=$(jq '[.[] | select(.rule.severity == "warning")] | length' "$alerts")
  other=$((total - errors - warnings))
  day=$(date -u +%Y-%m-%d)
  link="https://github.com/${ORG}/${repo}/security/code-scanning?query=is%3Aopen"

  echo "## Code-scanning digest — ${day}"
  echo
  echo "Open alerts in \`${ORG}/${repo}\`: **${total}** total — ${errors} error, ${warnings} warning, ${other} note/other."
  echo
  if [ "$errors" -gt 0 ]; then
    local rows n_rules
    rows=$(mktemp)
    jq -r '
      [.[] | select(.rule.severity == "error")]
      | group_by(.rule.id // "unknown")
      | sort_by(-length)
      | .[]
      | "| `\(.[0].rule.id // "unknown")` | \(length) | \([.[0:3][] | "\(.most_recent_instance.location.path // "?"):\(.number)"] | join(", ")) |"
    ' "$alerts" > "$rows"
    n_rules=$(wc -l < "$rows")
    echo "### Error-severity rules"
    echo
    echo "| Rule | Open alerts | Example locations (path:alert) |"
    echo "|---|---|---|"
    head -n "$MAX_RULE_ROWS" "$rows"
    if [ "$n_rules" -gt "$MAX_RULE_ROWS" ]; then
      echo
      echo "…plus $((n_rules - MAX_RULE_ROWS)) more error-severity rules — see the [full list](${link})."
    fi
    rm -f "$rows"
  else
    echo "No error-severity alerts are open."
  fi
  echo
  echo "Warning/note alerts roll up into the counts above and are not listed individually."
  echo
  echo "Full list: ${link}"
  echo
  echo "_Auto-filed on a schedule by the org SARIF-triage workflow (zeroroot-ai/.github). One digest issue per repo, found by title and updated in place; repos with zero open alerts are skipped. Fix alerts to close them, or dismiss them with a reason per slice 4.6 suppression discipline (ADR-0013)._"
}

# build_digest_summary <repo> <alerts_file> — fallback when the full digest
# exceeds MAX_BODY_BYTES: counts + link only.
build_digest_summary() {
  local repo="$1" alerts="$2"
  local total errors warnings other n_rules day link
  total=$(jq 'length' "$alerts")
  errors=$(jq '[.[] | select(.rule.severity == "error")] | length' "$alerts")
  warnings=$(jq '[.[] | select(.rule.severity == "warning")] | length' "$alerts")
  other=$((total - errors - warnings))
  n_rules=$(jq '[.[] | select(.rule.severity == "error") | .rule.id] | unique | length' "$alerts")
  day=$(date -u +%Y-%m-%d)
  link="https://github.com/${ORG}/${repo}/security/code-scanning?query=is%3Aopen"

  echo "## Code-scanning digest — ${day}"
  echo
  echo "Open alerts in \`${ORG}/${repo}\`: **${total}** total — ${errors} error, ${warnings} warning, ${other} note/other."
  echo
  echo "The per-rule detail table exceeded the digest size cap and was omitted (${n_rules} error-severity rules affected)."
  echo
  echo "Full list: ${link}"
  echo
  echo "_Auto-filed on a schedule by the org SARIF-triage workflow (zeroroot-ai/.github). One digest issue per repo, found by title and updated in place; repos with zero open alerts are skipped._"
}

# render_digest <repo> <alerts_file> <out_file> — full digest, with the byte
# cap applied as a backstop.
render_digest() {
  local repo="$1" alerts="$2" out="$3"
  build_digest "$repo" "$alerts" > "$out"
  if [ "$(wc -c < "$out")" -gt "$MAX_BODY_BYTES" ]; then
    build_digest_summary "$repo" "$alerts" > "$out"
  fi
}

# ---------------------------------------------------------------------------
# file_digest <repo> <total_open> <body_file>
# Finds the repo's digest issue by title prefix and updates it in place, or
# creates it if absent. HARD SAFETY: aborts the whole run if it would create
# a second NEW issue in the same repo in one run.
file_digest() {
  local repo="$1" total="$2" body_file="$3"
  local title="${TITLE_PREFIX} — ${total} open alerts"
  local existing
  if ! existing=$(gh issue list -R "${ORG}/${repo}" --state open \
        --search "in:title \"${TITLE_PREFIX}\"" \
        --json number --jq '.[0].number // empty'); then
    echo "::error::${ORG}/${repo}: failed to query for an existing digest issue — not filing"
    return 1
  fi

  if [ -n "$existing" ]; then
    if gh issue edit "$existing" -R "${ORG}/${repo}" --title "$title" --body-file "$body_file" >/dev/null; then
      echo "${ORG}/${repo}: updated digest issue #${existing} in place"
    else
      echo "::error::${ORG}/${repo}: failed to update digest issue #${existing}"
      return 1
    fi
  else
    if [ "${CREATED_PER_REPO[$repo]:-0}" -ge 1 ]; then
      echo "::error::SAFETY ABORT: about to create a SECOND new issue in ${ORG}/${repo} in one run — the one-digest-per-repo invariant is broken; aborting the entire run before filing anything else"
      exit 1
    fi
    local url
    if url=$(gh issue create -R "${ORG}/${repo}" --title "$title" --body-file "$body_file" --label "ready-for-agent" 2>/dev/null) \
       || url=$(gh issue create -R "${ORG}/${repo}" --title "$title" --body-file "$body_file"); then
      CREATED_PER_REPO[$repo]=$(( ${CREATED_PER_REPO[$repo]:-0} + 1 ))
      echo "${ORG}/${repo}: created digest issue ${url}"
    else
      echo "::error::${ORG}/${repo}: failed to create digest issue"
      return 1
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# process_repo <repo> — fetch, skip-or-render, file. Returns 0 on ok/skip,
# 1 on an error that must turn the run red (after all repos are processed).
process_repo() {
  local repo="$1"
  local alerts rc=0
  alerts=$(mktemp)
  fetch_alerts "$repo" "$alerts" || rc=$?

  if [ "$rc" -eq "$RC_SKIP" ]; then
    echo "${ORG}/${repo}: code scanning not enabled / no analyses — skipped, nothing filed"
    rm -f "$alerts"
    return 0
  elif [ "$rc" -ne 0 ]; then
    echo "::error::${ORG}/${repo}: code-scanning API request failed or returned a malformed response — skipped, NOT filed as an issue (details above)"
    rm -f "$alerts"
    return 1
  fi

  local total
  total=$(jq 'length' "$alerts")
  if [ "$total" -eq 0 ]; then
    echo "${ORG}/${repo}: zero open code-scanning alerts — skipped, nothing filed"
    rm -f "$alerts"
    return 0
  fi

  local body frc=0
  body=$(mktemp)
  render_digest "$repo" "$alerts" "$body"
  file_digest "$repo" "$total" "$body" || frc=1
  rm -f "$alerts" "$body"
  return "$frc"
}

# ---------------------------------------------------------------------------
main() {
  local repos
  repos=$(gh api "orgs/${ORG}/repos" --paginate --jq '.[].name' | \
          grep -vE '^(\.github|.*\.github\.io)$')

  # Blind-spot guard (kept from .github#243): `gitops` is a known private,
  # long-lived repo. If it is absent the token cannot see private repos and
  # the triage would be a false all-clear for them — fail loudly instead.
  if ! printf '%s\n' "$repos" | grep -qx 'gitops'; then
    echo "::error::repo enumeration is missing private repos (gitops not visible) — GH_PAT_PLATFORM_RO is unset or lacks org read; triage would silently cover public repos only"
    exit 1
  fi

  local failures=0 repo
  for repo in $repos; do
    process_repo "$repo" || failures=$((failures + 1))
  done

  if [ "$failures" -gt 0 ]; then
    echo "::error::${failures} repo(s) hit API errors or filing failures this run — see the log above; those repos were NOT filed against"
    exit 1
  fi
  echo "triage complete: all repos processed"
}

# Run main only when executed directly — the fixture self-test
# (scripts/test-sarif-triage.sh) sources this file to test the functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
