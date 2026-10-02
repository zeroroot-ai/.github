#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Zero Root AI
#
# Proves actions/deadcode-gate/deadcode-gate.sh can fail (.github#159).
#
# WHY THIS EXISTS SEPARATELY: reusable-go-ci.yml is `workflow_call:` only, so
# nothing in this repo exercises the gate it ships. Same reason
# gitleaks-gate-selftest.yml exists. Every fixture module is generated at run
# time, so no deliberately dead code is committed here.
#
# "Every new guard ships with a failing fixture in the same PR. A guard that
# cannot fail is worse than no guard."
set -euo pipefail

cd "$(dirname "$0")/.."
GATE="$PWD/actions/deadcode-gate/deadcode-gate.sh"

# The version the fixture installs. Kept here, not in the gate: the gate takes
# the pin from its caller precisely so it has no default.
VER="${DEADCODE_TEST_VERSION:-v0.50.0}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok()   { echo "PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }

# fixture <dir> <extra-go-source>
# A module with a reachable main, plus whatever the case adds.
fixture() {
  local d="$1" extra="${2:-}"
  mkdir -p "$d"
  cat > "$d/go.mod" <<EOF
module deadcodefixture

go 1.24
EOF
  cat > "$d/main.go" <<'EOF'
package main

func Reachable() string { return "reached" }

func main() { _ = Reachable() }
EOF
  [ -n "$extra" ] && printf '%s\n' "$extra" > "$d/extra.go"
  return 0
}

run_gate() { # <dir> [allowlist]
  local d="$1" al="${2:-}"
  if [ -n "$al" ]; then
    "$GATE" --version "$VER" --dir "$d" --allowlist "$al" 2>&1
  else
    "$GATE" --version "$VER" --dir "$d" 2>&1
  fi
}

# --- 1. a clean module passes, and says how much it looked at ----------------
fixture "$tmp/clean"
if out="$(run_gate "$tmp/clean")"; then
  if printf '%s' "$out" | grep -q 'unreachable func(s) found'; then
    ok "a clean module passes and reports a count"
  else
    bad "a clean module passed but printed no count: $out"
  fi
else
  bad "a clean module was rejected: $out"
fi

# --- 2. a planted unreachable function FAILS --------------------------------
fixture "$tmp/dead" 'package main

func NeverCalled() string { return "dead" }'
if out="$(run_gate "$tmp/dead")"; then
  bad "a planted unreachable function passed the gate: $out"
else
  if printf '%s' "$out" | grep -q 'NeverCalled'; then
    ok "a planted unreachable function fails and is named"
  else
    bad "the gate failed but did not name NeverCalled: $out"
  fi
fi

# --- 3. the allowlist tolerates exactly that symbol -------------------------
fixture "$tmp/allowed" 'package main

func NeverCalled() string { return "dead" }'
# The key is EXACTLY what deadcode prints after "unreachable func: ", which for a
# main package is the bare name. Measured, not assumed: deadcode reports
#   extra.go:3:6: unreachable func: NeverCalled
printf '# the planted case\nNeverCalled\n' > "$tmp/allowed/allow.txt"
if out="$(run_gate "$tmp/allowed" allow.txt)"; then
  ok "an allowlisted symbol is tolerated"
else
  bad "an allowlisted symbol still failed: $out"
fi

# --- 4. an allowlist entry naming nothing FAILS -----------------------------
# An exemption that outlives its reason is worse than none: it reads as reviewed.
fixture "$tmp/stale"
printf 'GoneLongAgo\n' > "$tmp/stale/allow.txt"
if out="$(run_gate "$tmp/stale" allow.txt)"; then
  bad "an allowlist entry naming a symbol deadcode never reported passed: $out"
else
  if printf '%s' "$out" | grep -q 'GoneLongAgo'; then
    ok "a stale allowlist entry fails and is named"
  else
    bad "the gate failed but did not name the stale entry: $out"
  fi
fi

# --- 5. a missing allowlist file FAILS, rather than tolerating nothing ------
fixture "$tmp/noal"
if out="$(run_gate "$tmp/noal" absent.txt)"; then
  bad "a missing allowlist file was treated as an empty one: $out"
else
  ok "a missing allowlist file fails with a wiring message"
fi

# --- 6. no --version FAILS --------------------------------------------------
fixture "$tmp/nover"
if out="$("$GATE" --dir "$tmp/nover" 2>&1)"; then
  bad "the gate ran with no pinned version: $out"
else
  ok "a missing --version fails"
fi

# --- 7. a module that does not compile FAILS, and is not read as clean ------
# The trap this gate exists around: an analysis error writes nothing to stdout,
# which is indistinguishable from "no dead code" to a gate that reads stdout only.
fixture "$tmp/broken" 'package main

func Broken() { return undefinedThing }'
if out="$(run_gate "$tmp/broken")"; then
  bad "a module that does not compile passed the gate: $out"
else
  if printf '%s' "$out" | grep -q 'read no code'; then
    ok "an analysis error fails and says it is not a pass"
  else
    bad "the gate failed but not with the analysed-nothing message: $out"
  fi
fi

# --- 8. a stub deadcode earlier on PATH is IGNORED --------------------------
# The gate resolves the binary it installed, so PATH order cannot decide which
# one analyses the module. A stub that exits 0 would otherwise report every
# module clean. This case asserts it is ignored, not that it is caught: the gate
# must still find the planted dead function.
fixture "$tmp/impostor" 'package main

func NeverCalled() string { return "dead" }'
stub="$tmp/stubbin"
mkdir -p "$stub"
printf '#!/bin/sh\nexit 0\n' > "$stub/deadcode"
chmod +x "$stub/deadcode"
if out="$(PATH="$stub:$PATH" "$GATE" --version "$VER" --dir "$tmp/impostor" 2>&1)"; then
  bad "a stub deadcode earlier on PATH was used, so the gate reported a dead function clean: $out"
else
  if printf '%s' "$out" | grep -q 'NeverCalled'; then
    ok "a stub deadcode earlier on PATH is ignored"
  else
    bad "the gate failed, but not by finding NeverCalled: $out"
  fi
fi

# --- 9. a library module with no main says SO, not "could not analyse" ----------
# Whole-program reachability needs an entry point. Without one deadcode exits
# non-zero with "no main packages", which the generic analysis-failure message
# would blame on the toolchain. It must still FAIL — a caller that switched the
# input on asked for a gate it will not get — but the message has to send the
# reader to unwired rather than to a version bump.
mkdir -p "$tmp/libonly"
cat > "$tmp/libonly/go.mod" <<'EOF'
module libonly

go 1.24
EOF
cat > "$tmp/libonly/lib.go" <<'EOF'
package libonly

// Exported is public API with no main to be reachable from.
func Exported() string { return "x" }
EOF
if out="$(run_gate "$tmp/libonly")"; then
  bad "a library module with no main passed, so the gate did nothing and said nothing"
else
  if printf '%s' "$out" | grep -q 'no main package, so whole-program reachability does'; then
    if printf '%s' "$out" | grep -q 'unwired'; then
      ok "a module with no main is named as such and pointed at unwired"
    else
      bad "the no-main message does not mention unwired: $out"
    fi
  else
    bad "a module with no main got the generic analysis error instead of the specific one: $out"
  fi
fi

echo
echo "deadcode-gate selftest: ${pass} passed, ${fail} failed"
# A FLOOR. A selftest that ran no case is the worst kind of green.
if [ "$pass" -lt 9 ] && [ "$fail" -eq 0 ]; then
  echo "FAIL: only ${pass} case(s) ran; the harness is not exercising the gate" >&2
  exit 1
fi
[ "$fail" -eq 0 ] || exit 1
echo "✅ deadcode-gate selftest: ${pass} cases, the gate can fail and passes a clean module"
