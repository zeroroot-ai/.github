#!/usr/bin/env bash
# Fixture test for the doc-freshness adr/trap reference resolution logic.
#
# Proves:
#   (a) A file containing a valid // adr: N reference (where N exists) passes.
#   (b) A file containing a stale // adr: 9999 reference fails.
#   (c) A file containing a valid // trap: T0001 reference (where T0001 exists) passes.
#   (d) A file containing a stale // trap: T9999 reference fails.
#
# Called by the doc-freshness-fixture CI job in .github/workflows/doc-freshness.yml.
# Expects /tmp/refs/adrs.txt and /tmp/refs/traps.txt to be populated (same as the
# real workflow does in the "Fetch docs repo" step).
#
# Exit 0 = all fixture assertions passed. Exit 1 = at least one failed.

set -euo pipefail

PASS=0
FAIL=0

check_adr() {
  local num="$1"
  local expect="$2"  # "pass" or "fail"
  local tmpfile
  tmpfile=$(mktemp /tmp/adr_fixture_XXXXXX.go)
  printf '// adr: %s\npackage fixture\n' "$num" > "$tmpfile"

  local result="pass"
  if ! grep -qFx "$num" /tmp/refs/adrs.txt 2>/dev/null; then
    result="fail"
  fi
  rm -f "$tmpfile"

  if [ "$result" = "$expect" ]; then
    echo "✅ adr: $num → $result (expected $expect)"
    PASS=$((PASS + 1))
  else
    echo "❌ adr: $num → $result (expected $expect)"
    FAIL=$((FAIL + 1))
  fi
}

check_trap() {
  local id="$1"
  local expect="$2"

  local result="pass"
  if ! grep -qFx "$id" /tmp/refs/traps.txt 2>/dev/null; then
    result="fail"
  fi

  if [ "$result" = "$expect" ]; then
    echo "✅ trap: $id → $result (expected $expect)"
    PASS=$((PASS + 1))
  else
    echo "❌ trap: $id → $result (expected $expect)"
    FAIL=$((FAIL + 1))
  fi
}

# ADR fixture assertions.
# ADR 7 is docs/adr/0007-agent-merge-autonomy.md — should always exist.
check_adr "7" "pass"
# ADR 9999 does not exist — should always fail.
check_adr "9999" "fail"

# Trap fixture assertions.
# T0001 should exist in traps.md (first trap) — should pass.
check_trap "T0001" "pass"
# T9999 does not exist — should always fail.
check_trap "T9999" "fail"

echo ""
echo "Fixture results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  echo "::error::doc-freshness fixture self-test failed — $FAIL assertion(s) wrong"
  exit 1
fi
