#!/usr/bin/env bash
# check-makefile-contract.sh — every repo's Makefile exposes the contracted
# targets: build / test / check (slice 1.4 of the production-readiness epic,
# gibson#171 → board #16).
#
# Two modes:
#   --scan-dir <dir>   offline. Every immediate subdirectory of <dir> is a
#                      repo; the guard reads <dir>/<repo>/Makefile. Used by
#                      scripts/test-makefile-contract.sh.
#   (default)          live. Enumerates the org and reads each Makefile
#                      through the contents API. Needs GH_TOKEN.
#
# Live mode also files the drift report: ONE issue, found by title and
# updated in place, closed again when every repo passes. Pass --no-file to
# print the report and leave the tracker alone.
#
# Exempt repos (no Go service or library, so a Makefile build/test/check
# contract does not apply): charts and hosted (Helm + Terraform), the
# pnpm/TypeScript repos (dashboard, sdk-ts, zerocool-plugins — their contract
# is package.json scripts, and a stub Makefile wrapping pnpm would be a second
# entrypoint that drifts), the org repo, and the pages site.
#
# Token scope: enumeration uses GH_PAT_PLATFORM_RO so the audit can see
# PRIVATE org repos. With the default GITHUB_TOKEN `gh api orgs/.../repos`
# returns only PUBLIC repos, so the audit silently skips every private repo
# and reports a false "all clear" (.github#170). Live mode hard-fails if the
# private canary is not visible, so the blind spot cannot silently return.
set -euo pipefail

ORG=zeroroot-ai
CANARY=hosted
REQUIRED_TARGETS=(build test check)
EXEMPT_RE='^(\.github|charts|hosted|dashboard|sdk-ts|zerocool-plugins|.*\.github\.io)$'
TITLE_PREFIX="Makefile contract drift"

MODE=live
SCAN_DIR=""
FILE_ISSUE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --scan-dir) MODE=scan; SCAN_DIR="$2"; shift 2 ;;
    --no-file)  FILE_ISSUE=0; shift ;;
    *) echo "usage: $0 [--scan-dir DIR] [--no-file]" >&2; exit 2 ;;
  esac
done

# missing_targets <makefile-path> — prints the missing target names, space
# prefixed, empty when the Makefile satisfies the contract.
#
# grep reads the file directly. It must never read a pipeline: `echo "$VAR" |
# grep -q` lets grep exit on its FIRST match and kills the writer with
# SIGPIPE, and under `set -o pipefail` that status (141) is indistinguishable
# from "no match". The audit then reports targets the Makefile actually has.
# That is .github#141: gibson's 45 KB Makefile was reported as missing `test`
# and `check` while defining both, and the run log carried one
# "echo: write error: Broken pipe" per falsely-reported target. The race only
# fires once the content outgrows the reader's buffer, which is why it hit the
# largest Makefile in the org and nothing else.
missing_targets() {
  local makefile="$1" miss="" target
  for target in "${REQUIRED_TARGETS[@]}"; do
    if ! grep -qE "^${target}:" -- "$makefile"; then
      miss="${miss} ${target}"
    fi
  done
  printf '%s' "$miss"
}

TMPDIR_GUARD=$(mktemp -d)
trap 'rm -rf "$TMPDIR_GUARD"' EXIT

MISSING=""
record_drift() { MISSING="${MISSING}
- $1"; }

if [ "$MODE" = scan ]; then
  [ -d "$SCAN_DIR" ] || { echo "❌ --scan-dir $SCAN_DIR is not a directory" >&2; exit 2; }
  for path in "$SCAN_DIR"/*/; do
    [ -d "$path" ] || continue
    repo=$(basename "$path")
    [[ "$repo" =~ $EXEMPT_RE ]] && continue
    if [ ! -f "${path}Makefile" ]; then
      record_drift "$repo: no Makefile"
      continue
    fi
    fail=$(missing_targets "${path}Makefile")
    [ -n "$fail" ] && record_drift "$repo: missing target(s):${fail}"
  done
else
  : "${GH_TOKEN:?set GH_TOKEN (GH_PAT_PLATFORM_RO, so private repos are visible)}"
  ALL_REPOS=$(gh api "orgs/${ORG}/repos" --paginate --jq '.[].name')

  # Blind-spot guard: without private-repo read the enumeration silently
  # drops them and the audit becomes a false all-clear (.github#170). The
  # canary is checked against the UNFILTERED list because it is itself
  # exempt from the audit. A public canary could never fire, so it would
  # stop guarding.
  if ! grep -qx "$CANARY" <<< "$ALL_REPOS"; then
    echo "::error::repo enumeration is missing private repos ($CANARY not visible) — GH_PAT_PLATFORM_RO is unset or lacks org read; audit would be incomplete"
    exit 1
  fi

  while read -r repo; do
    [ -n "$repo" ] || continue
    [[ "$repo" =~ $EXEMPT_RE ]] && continue
    makefile="$TMPDIR_GUARD/$repo.Makefile"
    if ! gh api "/repos/${ORG}/${repo}/contents/Makefile" --jq '.content' 2>/dev/null \
         | base64 -d > "$makefile" 2>/dev/null || [ ! -s "$makefile" ]; then
      record_drift "$repo: no Makefile"
      continue
    fi
    fail=$(missing_targets "$makefile")
    [ -n "$fail" ] && record_drift "$repo: missing target(s):${fail}"
  done <<< "$ALL_REPOS"
fi

existing_issue() {
  gh issue list -R "${ORG}/.github" --state open \
    --search "in:title \"${TITLE_PREFIX}\"" --json number --jq '.[0].number // empty'
}

if [ -z "$MISSING" ]; then
  echo "::notice::all repos pass the Makefile contract (${REQUIRED_TARGETS[*]})"
  if [ "$MODE" = scan ] || [ "$FILE_ISSUE" = 0 ]; then
    exit 0
  fi
  # Self-heal: close a stale drift issue so the tracker reflects the clean
  # state instead of lingering open.
  open=$(existing_issue)
  if [ -n "$open" ]; then
    gh issue close "$open" -R "${ORG}/.github" \
      --comment "All repos now satisfy the Makefile contract (${REQUIRED_TARGETS[*]}). Auto-closed by the makefile-contract audit."
  fi
  exit 0
fi

printf 'Makefile contract drift:%s\n' "$MISSING"

BODY="## Makefile contract drift report

Per slice 1.4 every repo's Makefile must expose \`build\`, \`test\`, \`check\` targets.

Drifted repos:${MISSING}

For the canonical contract, see workspace CLAUDE.md + the production-readiness PRD at gibson#171."

if [ "$MODE" = scan ] || [ "$FILE_ISSUE" = 0 ]; then
  exit 1
fi

TITLE="${TITLE_PREFIX} — $(date -u +%Y-%m-%d)"
open=$(existing_issue)
if [ -n "$open" ]; then
  printf '%s' "$BODY" | gh issue edit "$open" -R "${ORG}/.github" --title "$TITLE" --body-file -
else
  printf '%s' "$BODY" | gh issue create -R "${ORG}/.github" --title "$TITLE" --body-file - --label "ready-for-agent"
fi
