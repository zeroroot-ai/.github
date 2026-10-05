#!/usr/bin/env bash
# check-ruleset-review-rule.sh - no ruleset requires a review or a signed commit.
#
# ADR-0168: CI is the gate. A pull request needs no approving review, and a
# commit needs no signature. The owner works alone with agents, so a required
# review has no second person to give it. A ruleset file that adds one of the
# two rules stops each merge in each repo of its tier.
#
# The guard reads each JSON file under rulesets/ and fails on:
#
#   1. a `required_approving_review_count` that is not 0,
#   2. a `require_code_owner_review` or `require_last_push_approval` that is true,
#   3. a rule of type `required_signatures`.
#
# It fails too when it reads fewer than MIN_FILES files, so a wrong directory
# never passes.
#
# Usage: scripts/check-ruleset-review-rule.sh [rulesets-dir]
# Exit codes: 0 clean, 1 finding, 2 setup error.
set -euo pipefail

DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/rulesets}"
MIN_FILES="${MIN_FILES:-10}"

[ -d "$DIR" ] || { echo "check-ruleset-review-rule: $DIR is not a directory" >&2; exit 2; }

fail=0
files=0
pull_rules=0
while IFS= read -r -d '' f; do
  files=$((files + 1))
  rel="${f#"$DIR"/}"
  if ! jq -e . "$f" >/dev/null 2>&1; then
    echo "check-ruleset-review-rule: rulesets/$rel is not valid JSON" >&2
    exit 2
  fi
  n=$(jq '[.rules[]? | select(.type == "pull_request")] | length' "$f")
  pull_rules=$((pull_rules + n))
  while IFS= read -r finding; do
    [ -z "$finding" ] && continue
    echo "check-ruleset-review-rule: rulesets/$rel: $finding (ADR-0168)" >&2
    fail=1
  done < <(jq -r '
    .rules[]? |
    if .type == "required_signatures" then
      "the rule required_signatures requires a signed commit"
    elif .type == "pull_request" then
      (.parameters // {}) as $p |
      (if ($p.required_approving_review_count // 0) != 0
         then "required_approving_review_count is \($p.required_approving_review_count), and it must be 0" else empty end),
      (if $p.require_code_owner_review == true
         then "require_code_owner_review is true, and it must be false" else empty end),
      (if $p.require_last_push_approval == true
         then "require_last_push_approval is true, and it must be false" else empty end)
    else empty end' "$f")
done < <(find "$DIR" -name '*.json' -print0 | sort -z)

if [ "$files" -lt "$MIN_FILES" ]; then
  echo "check-ruleset-review-rule: read $files file(s) under $DIR, and the floor is $MIN_FILES" >&2
  exit 2
fi
if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "check-ruleset-review-rule: OK. $files ruleset file(s), $pull_rules pull request rule(s): no review and no signed commit is required."
