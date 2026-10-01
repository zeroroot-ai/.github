#!/usr/bin/env bash
# Mutation tests for scripts/check-repo-merge-settings-drift.sh. Each case
# breaks one thing and REQUIRES a red; the pass cases prove it is not failing
# indiscriminately. Run by drift-guard-fixtures in ruleset-drift.yml.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/check-repo-merge-settings-drift.sh"
PASS=0
FAIL=0

CLEAN=$(printf '%s\n' \
  'gibson	PR_TITLE	COMMIT_MESSAGES	true' \
  'hosted	PR_TITLE	COMMIT_MESSAGES	true' \
  'brand	PR_TITLE	COMMIT_MESSAGES	true')

run() {
  MERGE_FETCH_CMD="printf '%s\n' \"\$FLEET\"" FLEET="$1" bash "$GUARD" >/dev/null 2>&1
}
assert_fails() {
  local label="$1" fleet="$2"
  if run "$fleet"; then echo "  NOT DETECTED: $label"; FAIL=$((FAIL+1)); else echo "  detected:     $label"; PASS=$((PASS+1)); fi
}
assert_passes() {
  local label="$1" fleet="$2"
  if run "$fleet"; then echo "  clean:        $label"; PASS=$((PASS+1)); else echo "  FALSE ALARM:  $label"; FAIL=$((FAIL+1)); fi
}

echo "mutations the guard must catch:"
assert_fails "title back to COMMIT_OR_PR_TITLE (the hosted#264 state)" \
  "$(printf '%s\n' 'gibson	COMMIT_OR_PR_TITLE	COMMIT_MESSAGES	true')"
assert_fails "title MERGE_MESSAGE" \
  "$(printf '%s\n' 'gibson	MERGE_MESSAGE	COMMIT_MESSAGES	true')"
assert_fails "message PR_BODY (drops commit trailers)" \
  "$(printf '%s\n' 'gibson	PR_TITLE	PR_BODY	true')"
assert_fails "message BLANK" \
  "$(printf '%s\n' 'gibson	PR_TITLE	BLANK	true')"
assert_fails "field absent, not merely wrong" \
  "$(printf '%s\n' 'gibson	absent	absent	false')"
assert_fails "one drifted repo among clean ones" \
  "$(printf '%s\n%s\n' "$CLEAN" 'sdk	COMMIT_OR_PR_TITLE	COMMIT_MESSAGES	true')"
assert_fails "an empty fleet (a vacuous scan is not a pass)" ""

# allow_auto_merge off is the setting that silently defeats the Dependabot
# sweeper: `gh pr merge --auto` is refused on such a repo, so a PR looks
# armed while nothing armed it. It was off on eight of sixteen repos.
assert_fails "allow_auto_merge off" \
  "$(printf '%s\n' 'gibson	PR_TITLE	COMMIT_MESSAGES	false')"
assert_fails "one repo with auto-merge off among clean ones" \
  "$(printf '%s\n%s\n' "$CLEAN" 'sdk	PR_TITLE	COMMIT_MESSAGES	false')"
assert_fails "allow_auto_merge column missing entirely" \
  "$(printf '%s\n' 'gibson	PR_TITLE	COMMIT_MESSAGES')"

echo "cases the guard must NOT flag:"
assert_passes "the clean fleet" "$CLEAN"
assert_passes "a single clean repo" "$(printf '%s\n' 'brand	PR_TITLE	COMMIT_MESSAGES	true')"

echo "spec integrity:"
tmpspec=$(mktemp)
printf '%s\n' '{"squash_merge_commit_title":"PR_TITLE","squash_merge_commit_message":"COMMIT_MESSAGES"}' >"$tmpspec"
if MERGE_SETTINGS_SPEC="$tmpspec" MERGE_FETCH_CMD="printf '%s\n' \"\$FLEET\"" FLEET="$CLEAN" bash "$GUARD" >/dev/null 2>&1; then
  echo "  NOT DETECTED: a spec with no allow_auto_merge passes"; FAIL=$((FAIL+1))
else
  echo "  detected:     a spec with no allow_auto_merge fails"; PASS=$((PASS+1))
fi
rm -f "$tmpspec"
if MERGE_SETTINGS_SPEC=/dev/null MERGE_FETCH_CMD="printf '%s\n' \"\$FLEET\"" FLEET="$CLEAN" bash "$GUARD" >/dev/null 2>&1; then
  echo "  NOT DETECTED: empty spec passes"; FAIL=$((FAIL+1))
else
  echo "  detected:     empty spec fails"; PASS=$((PASS+1))
fi

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
