#!/usr/bin/env bash
# Mutation test for scripts/check-security-features-drift.sh.
#
# A drift guard that cannot go red is worth less than no guard, because it gets
# read as evidence. Every assertion below MUTATES one field of a simulated fleet
# and requires the guard to fail on it. The pass-cases exist only to prove the
# guard is not simply failing on everything.
#
# No network and no org token: the guard's live fetch is injected through
# SECURITY_FETCH_CMD, so this runs in the pull_request lane.
#
# Exit 0 = every assertion held.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/check-security-features-drift.sh"
PASS=0
FAIL=0

# name  visibility  language  secret  push  code_security
CLEAN=$(printf '%s\n' \
  'gibson	public	Go	enabled	enabled	absent' \
  'hosted	private	Shell	enabled	enabled	disabled' \
  'sdk	private	Go	enabled	enabled	enabled' \
  'brand	private	CSS	enabled	enabled	disabled')

run() { SECURITY_FETCH_CMD="printf '%s\n' \"\$FLEET\"" FLEET="$1" bash "$GUARD" >/dev/null 2>&1; }

assert_fails() {
  local label="$1" fleet="$2"
  if run "$fleet"; then
    echo "  NOT DETECTED: $label"; FAIL=$((FAIL+1))
  else
    echo "  detected:     $label"; PASS=$((PASS+1))
  fi
}
assert_passes() {
  local label="$1" fleet="$2"
  if run "$fleet"; then
    echo "  clean:        $label"; PASS=$((PASS+1))
  else
    echo "  FALSE ALARM:  $label"; FAIL=$((FAIL+1))
  fi
}

echo "mutations the guard must catch:"

# Tier 1 is universal — every one of these must fail, including on repos that
# carry no code at all.
assert_fails "secret scanning off on a public repo" \
  "$(printf '%s\n' 'gibson	public	Go	disabled	enabled	absent')"
assert_fails "secret scanning off on a private repo" \
  "$(printf '%s\n' 'hosted	private	Shell	disabled	enabled	disabled')"
assert_fails "push protection off, scanning on" \
  "$(printf '%s\n' 'hosted	private	Shell	enabled	disabled	disabled')"
assert_fails "tier 1 off on a CSS repo — 'nothing to scan' is not an exemption" \
  "$(printf '%s\n' 'brand	private	CSS	disabled	disabled	disabled')"
assert_fails "the field is missing entirely, not merely disabled" \
  "$(printf '%s\n' 'hosted	private	Shell	absent	absent	disabled')"

# Tier 2 keys on language, not on importance.
assert_fails "code scanning off on a private Go repo" \
  "$(printf '%s\n' 'sdk	private	Go	enabled	enabled	disabled')"
assert_fails "code scanning off on a private TypeScript repo" \
  "$(printf '%s\n' 'sdk-ts	private	TypeScript	enabled	enabled	disabled')"

# One bad repo in an otherwise clean fleet must still fail.
assert_fails "one drifted repo among four clean ones" \
  "$(printf '%s\n%s\n' "$CLEAN" 'integrations	private	Go	enabled	disabled	enabled')"

# Vacuous input must never pass.
assert_fails "an empty fleet (a vacuous scan is not a pass)" ""

echo "cases the guard must NOT flag:"

assert_passes "the clean fleet" "$CLEAN"
assert_passes "code scanning off where CodeQL cannot run (CSS)" \
  "$(printf '%s\n' 'brand	private	CSS	enabled	enabled	disabled')"
assert_passes "public repo reporting code_security absent" \
  "$(printf '%s\n' 'gibson	public	Go	enabled	enabled	absent')"

echo "---"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
