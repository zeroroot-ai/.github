#!/usr/bin/env bash
# Fixture + regression tests for scripts/check-makefile-contract.sh.
#
# The case that matters is `large Makefile`. The guard used to read
# `echo "$MAKEFILE" | grep -qE "^${T}:"`. grep -q exits on its first match,
# the writer then dies of SIGPIPE, and `set -o pipefail` reports that as a
# failed pipeline — which the guard could not tell apart from "no match". It
# only fires once the content outgrows the reader's buffer, so every small
# fixture passed and the org's largest Makefile (gibson, 45 KB) was reported
# as missing two targets it defines (.github#141).
#
# So the fixture has to be big. It is generated here rather than committed.
set -uo pipefail
cd "$(dirname "$0")/.."
G=scripts/check-makefile-contract.sh
F=tests/fixtures/makefile-contract
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

expect() { # <scan-dir> <want-rc> <must-contain|-> <label>
  local dir="$1" rc_want="$2" needle="$3" label="$4"
  local out rc
  out=$(bash "$G" --scan-dir "$dir" 2>&1); rc=$?
  if [ "$rc" != "$rc_want" ]; then
    bad "$label (rc=$rc, want $rc_want)"; printf '%s\n' "$out" | sed 's/^/     /'; return
  fi
  if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    bad "$label (missing \"$needle\")"; printf '%s\n' "$out" | sed 's/^/     /'; return
  fi
  ok "$label"
}

absent() { # <scan-dir> <must-not-contain> <label>
  local dir="$1" needle="$2" label="$3" out
  out=$(bash "$G" --scan-dir "$dir" 2>&1)
  if printf '%s' "$out" | grep -qF -- "$needle"; then
    bad "$label"; printf '%s\n' "$out" | sed 's/^/     /'
  else ok "$label"; fi
}

one() { # build a scan dir holding a single fixture
  local name="$1"
  local dest="$WORK/only-$name"
  mkdir -p "$dest"; cp -r "$F/$name" "$dest/"; printf '%s' "$dest"
}

expect "$(one complete)"     0 "all repos pass"            "a complete Makefile passes"
expect "$(one missing-test)" 1 "missing target(s): test"   "a missing target is named"
absent "$(one missing-test)" "build"                        "a present target is not named"
expect "$(one missing-all)"  1 "missing target(s): build test check" "all three missing are named"
expect "$(one no-makefile)"  1 "no Makefile"               "a repo with no Makefile is drift"
expect "$(one charts)"       0 "all repos pass"            "an exempt repo with no Makefile is skipped"
expect "$F"                  1 "missing target(s)"         "a mixed scan reports the drifted repos"

# --- the .github#141 regression -------------------------------------------
# A Makefile that satisfies the contract and is far larger than a pipe buffer
# (65536 bytes on Linux by default). The contracted targets sit at the very
# top, so a reader that stops at its first match leaves the bulk unread, which
# is exactly the condition that killed the writer.
BIG="$WORK/large/large_complete"
mkdir -p "$BIG"
{
  printf '.PHONY: build test check\n'
  printf 'build:\n\tgo build ./...\n\n'
  printf 'test:\n\tgo test ./...\n\n'
  printf 'check: test\n\tgo vet ./...\n\n'
  printf '# padding so the file outgrows any reader buffer, see .github#141\n'
  for i in $(seq 1 6000); do
    printf 'filler-target-%s: ## keep this Makefile large enough to race\n\t@echo %s\n' "$i" "$i"
  done
} > "$BIG/Makefile"
SIZE=$(wc -c < "$BIG/Makefile")
if [ "$SIZE" -lt 262144 ]; then
  bad "the large fixture is only $SIZE bytes; it must dwarf a 65536-byte pipe buffer"
else
  ok "the large fixture is $SIZE bytes"
fi
expect "$WORK/large" 0 "all repos pass" "a LARGE complete Makefile passes (.github#141 regression)"

# Content-keyed guard against the reintroduction of the pipeline. Keyed by
# shape, never by line number, so an unrelated edit cannot re-pin it.
if grep -nE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q' "$G"; then
  bad "$G pipes into \`grep -q\`; grep must read the file so SIGPIPE cannot masquerade as no-match"
else
  ok "no \`| grep -q\` pipeline in the guard"
fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
