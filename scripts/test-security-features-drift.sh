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

# name  visibility  language  secret  push  code_security  manifests  dependabot  code_scanning
CLEAN=$(printf '%s\n' \
  'gibson	public	Go	enabled	enabled	absent	3	true	workflow' \
  'hosted	private	Shell	enabled	enabled	disabled	3	true	workflow' \
  'sdk	private	Go	enabled	enabled	enabled	3	true	workflow' \
  'brand	private	CSS	enabled	enabled	disabled	3	true	workflow')

# default_workflow_permissions  can_approve_pull_request_reviews  sha_pinning_required
ORG_CLEAN=$(printf 'read\tfalse\ttrue')
# run <fleet> [<org record>] — the org record defaults to the clean one, so
# every repo-level fixture below is unchanged by the org assertions.
run() {
  SECURITY_FETCH_CMD="printf '%s\n' \"\$FLEET\"" FLEET="$1" \
  ORG_SETTINGS_FETCH_CMD="printf '%s\n' \"\$ORGSET\"" ORGSET="${2:-$ORG_CLEAN}" \
  bash "$GUARD" >/dev/null 2>&1
}

assert_fails() {
  local label="$1" fleet="$2" org="${3:-}"
  if run "$fleet" "$org"; then
    echo "  NOT DETECTED: $label"; FAIL=$((FAIL+1))
  else
    echo "  detected:     $label"; PASS=$((PASS+1))
  fi
}
assert_passes() {
  local label="$1" fleet="$2" org="${3:-}"
  if run "$fleet" "$org"; then
    echo "  clean:        $label"; PASS=$((PASS+1))
  else
    echo "  FALSE ALARM:  $label"; FAIL=$((FAIL+1))
  fi
}

echo "mutations the guard must catch:"

# Tier 1 is universal — every one of these must fail, including on repos that
# carry no code at all.
assert_fails "secret scanning off on a public repo" \
  "$(printf '%s\n' 'gibson	public	Go	disabled	enabled	absent	3	true	workflow')"
assert_fails "secret scanning off on a private repo" \
  "$(printf '%s\n' 'hosted	private	Shell	disabled	enabled	disabled	3	true	workflow')"
assert_fails "push protection off, scanning on" \
  "$(printf '%s\n' 'hosted	private	Shell	enabled	disabled	disabled	3	true	workflow')"
assert_fails "tier 1 off on a CSS repo — 'nothing to scan' is not an exemption" \
  "$(printf '%s\n' 'brand	private	CSS	disabled	disabled	disabled	3	true	workflow')"
assert_fails "the field is missing entirely, not merely disabled" \
  "$(printf '%s\n' 'hosted	private	Shell	absent	absent	disabled	3	true	workflow')"

# Tier 2 keys on language, not on importance.
assert_fails "code scanning off on a private Go repo" \
  "$(printf '%s\n' 'sdk	private	Go	enabled	enabled	disabled	3	true	workflow')"
assert_fails "code scanning off on a private TypeScript repo" \
  "$(printf '%s\n' 'sdk-ts	private	TypeScript	enabled	enabled	disabled	3	true	workflow')"

# One bad repo in an otherwise clean fleet must still fail.
assert_fails "one drifted repo among four clean ones" \
  "$(printf '%s\n%s\n' "$CLEAN" 'billing	private	Go	enabled	disabled	enabled	3	true	workflow')"

# Vacuous input must never pass.
assert_fails "an empty fleet (a vacuous scan is not a pass)" ""

echo "cases the guard must NOT flag:"

assert_passes "the clean fleet" "$CLEAN"
assert_passes "code scanning off where CodeQL cannot run (CSS)" \
  "$(printf '%s\n' 'brand	private	CSS	enabled	enabled	disabled	3	true	workflow')"
assert_passes "public repo reporting code_security absent" \
  "$(printf '%s\n' 'gibson	public	Go	enabled	enabled	absent	3	true	workflow')"

echo "tier 3, Dependabot security updates (.github#193):"
assert_fails "a repo with manifests and Dependabot security updates off" \
  "$(printf '%s\n' 'testharness	private	Go	enabled	enabled	enabled	2	false	none')"
assert_fails "one workflow file is a manifest too" \
  "$(printf '%s\n' 'site	public	CSS	enabled	enabled	absent	1	false	none')"
assert_fails "Dependabot state unreadable is not a pass" \
  "$(printf '%s\n' 'sdk	public	Go	enabled	enabled	absent	17	unreadable	workflow')"
assert_fails "a tree that could not be read is not a pass" \
  "$(printf '%s\n' 'sdk	public	Go	enabled	enabled	absent	unreadable	true	unreadable')"
assert_passes "a repo with no manifest needs no Dependabot" \
  "$(printf '%s\n' 'notes	private	CSS	enabled	enabled	disabled	0	false	none')"
assert_passes "manifests and Dependabot security updates on" \
  "$(printf '%s\n' 'sdk	public	Go	enabled	enabled	absent	17	true	workflow')"

echo "tier 2 on public repos (.github#193):"
assert_fails "a public Go repo with no CodeQL workflow and no default setup" \
  "$(printf '%s\n' 'cve-triage	public	Go	enabled	enabled	absent	7	true	none')"
assert_fails "a public TypeScript repo whose code scanning could not be read" \
  "$(printf '%s\n' 'sdk-ts	public	TypeScript	enabled	enabled	absent	9	true	unreadable')"
assert_passes "a public Go repo with default setup configured" \
  "$(printf '%s\n' 'cve-triage	public	Go	enabled	enabled	absent	7	true	default-setup')"
assert_passes "a public Go repo with a CodeQL workflow" \
  "$(printf '%s\n' 'gibson	public	Go	enabled	enabled	absent	32	true	workflow')"
assert_passes "a public repo in a language CodeQL cannot read" \
  "$(printf '%s\n' 'docs-site	public	MDX	enabled	enabled	absent	9	true	none')"

echo "org Actions settings the guard must catch (#75):"
# Each is the value the audit measured on 2026-09-16, planted one at a time
# against a clean fleet, so a failure here can only be the org check.
assert_fails "default_workflow_permissions write" "$CLEAN" "$(printf 'write\tfalse\ttrue')"
assert_fails "Actions may approve pull requests"  "$CLEAN" "$(printf 'read\ttrue\ttrue')"
assert_fails "sha_pinning_required off"           "$CLEAN" "$(printf 'read\tfalse\tfalse')"
assert_fails "org settings unreadable (absent)"   "$CLEAN" "$(printf 'absent\tabsent\tabsent')"
assert_passes "org settings as #75 wants them"    "$CLEAN" "$ORG_CLEAN"

echo "---"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
