#!/usr/bin/env bash
# Mutation tests for scripts/check-ruleset-review-rule.sh (ADR-0168, .github#192).
#
# Each failing case changes one thing in a copy of a clean ruleset tree and
# REQUIRES the guard to fail. No network, no token.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-ruleset-review-rule.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0

clean_tree() {
  local dir="$1"
  mkdir -p "$dir/org" "$dir/repo"
  jq -n '{name: "tier", rules: [
    {type: "deletion"},
    {type: "pull_request", parameters: {required_approving_review_count: 0,
      require_code_owner_review: false, require_last_push_approval: false}}]}' > "$dir/org/tier.json"
  jq -n '{name: "repo", rules: [{type: "required_status_checks", parameters: {}}]}' > "$dir/repo/a.json"
}

# assert <name> <pass|fail|setup> <dir> [MIN_FILES]
assert() {
  local name="$1" want="$2" dir="$3" min="${4:-2}" out rc
  set +e; out="$(MIN_FILES="$min" bash "$GUARD" "$dir" 2>&1)"; rc=$?; set -e
  case "$want" in
    pass)  [ "$rc" -eq 0 ] || { echo "FAIL [$name]: want exit 0, got $rc"; echo "$out"; exit 1; } ;;
    fail)  [ "$rc" -eq 1 ] || { echo "FAIL [$name]: want exit 1, got $rc"; echo "$out"; exit 1; } ;;
    setup) [ "$rc" -eq 2 ] || { echo "FAIL [$name]: want exit 2, got $rc"; echo "$out"; exit 1; } ;;
  esac
  pass=$((pass + 1))
  echo "ok   [$name]"
}

mutate() { # <dir> <jq filter on org/tier.json>
  local tmp; tmp="$(mktemp)"
  jq "$2" "$1/org/tier.json" > "$tmp" && mv "$tmp" "$1/org/tier.json"
}

clean_tree "$TMP/clean"
assert "a clean tree passes" pass "$TMP/clean"

clean_tree "$TMP/review"
mutate "$TMP/review" '.rules[1].parameters.required_approving_review_count = 1'
assert "a review count of 1 fails" fail "$TMP/review"

clean_tree "$TMP/owner"
mutate "$TMP/owner" '.rules[1].parameters.require_code_owner_review = true'
assert "a code owner review fails" fail "$TMP/owner"

clean_tree "$TMP/lastpush"
mutate "$TMP/lastpush" '.rules[1].parameters.require_last_push_approval = true'
assert "a last push approval fails" fail "$TMP/lastpush"

clean_tree "$TMP/signed"
mutate "$TMP/signed" '.rules += [{type: "required_signatures"}]'
assert "a signature rule fails" fail "$TMP/signed"

clean_tree "$TMP/repo-signed"
jq '.rules += [{type: "required_signatures"}]' "$TMP/repo-signed/repo/a.json" > "$TMP/x" && mv "$TMP/x" "$TMP/repo-signed/repo/a.json"
assert "a signature rule in a repo file fails" fail "$TMP/repo-signed"

clean_tree "$TMP/short"
assert "a tree under the file floor is a setup error" setup "$TMP/short" 3

clean_tree "$TMP/badjson"
echo '{' > "$TMP/badjson/repo/a.json"
assert "a file that is not JSON is a setup error" setup "$TMP/badjson"

assert "a missing directory is a setup error" setup "$TMP/none"

if [ "$pass" -lt 9 ]; then
  echo "FAIL: ran $pass case(s), and the floor is 9"; exit 1
fi
echo "test-ruleset-review-rule: $pass case(s) passed, 5 mutations failed the guard"
