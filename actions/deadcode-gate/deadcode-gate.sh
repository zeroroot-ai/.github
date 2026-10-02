#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Zero Root AI
#
# Whole-program dead-code gate, shared by every Go consumer of
# reusable-go-ci.yml (.github#159).
#
# ADR-0094 keeps this as the function-level FLOOR underneath the consumer-side
# gates. It is not the same question as ast-checks' `unwired` scanner: this
# answers "is this function reachable from a main", which cannot see a struct
# field, and `unwired` answers "does production code read this declaration",
# which can. Both are wanted; neither replaces the other.
#
# Before this existed, two repos of twelve had the gate and had each hand-written
# the same job, which is what the workspace rule forbids. This file is the one
# implementation; scripts/test-deadcode-gate.sh proves it can fail.
#
# Usage:
#   deadcode-gate.sh --version <x/tools ver> [--dir <module root>]
#                    [--allowlist <path relative to dir>]
#   deadcode-gate.sh --selftest-run ...   (used by test-deadcode-gate.sh)
#
# Exit 0 only when deadcode ANALYSED the module and reported nothing outside the
# allowlist.
set -euo pipefail

VERSION=""
DIR="."
ALLOWLIST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --version)   VERSION="$2"; shift 2 ;;
    --dir)       DIR="$2"; shift 2 ;;
    --allowlist) ALLOWLIST="$2"; shift 2 ;;
    *) echo "deadcode-gate: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$VERSION" ]; then
  cat >&2 <<'MSG'
deadcode-gate: --version is required.

The caller passes its Makefile's DEADCODE_VERSION so one pin serves a
developer's gate and CI's gate. Without it this script would install whatever
@latest resolves to today, and the gate would silently change meaning between
runs.
MSG
  exit 2
fi

cd "$DIR"

# ---------------------------------------------------------------------------
# 1. The pin must be the binary that runs.
# ---------------------------------------------------------------------------
# A gate that resolves its tool with `command -v` runs whatever PATH serves, so
# the pin decides nothing until the gate asserts the binary it ran. adk#82 pinned
# a version precisely so a developer's gate and CI's could not differ, and PATH
# then served an x/tools v0.44.0 deadcode from an older Go's packages dir, which
# cannot analyse a Go 1.27 module. The gate failed with an analysis error and
# pointed at the wrong remedy.
#
# A NEWER version fails too. The pin is the pin, not a floor.
echo "deadcode-gate: installing golang.org/x/tools/cmd/deadcode@${VERSION}"
GOFLAGS='' go install "golang.org/x/tools/cmd/deadcode@${VERSION}"

# Resolved EXPLICITLY from where `go install` put it, never with `command -v`.
# PATH order is not ours to control: on a developer box an asdf Go's packages dir
# routinely shadows GOPATH/bin, and this gate's own selftest hit it immediately —
# a v0.46.0 deadcode answered ahead of the v0.50.0 just installed. Asserting the
# version catches that, but resolving explicitly means it cannot arise.
bin="$(go env GOPATH)/bin/deadcode"
if [ ! -x "$bin" ]; then
  echo "deadcode-gate: ${bin} is missing after install" >&2
  exit 1
fi
have="$(go version -m "$bin" 2>/dev/null | awk '$1=="mod" && $2=="golang.org/x/tools"{print $3; exit}')"
if [ "$have" != "$VERSION" ]; then
  cat >&2 <<MSG
deadcode-gate: the deadcode that ran is x/tools ${have:-unreadable}, not ${VERSION}.
  resolved from PATH: ${bin}

The version is the pin. This is the binary that go install just wrote, so a
mismatch means the install did not do what it said, not that PATH interfered.
MSG
  exit 1
fi
echo "deadcode-gate: running x/tools ${have} from ${bin}"

# ---------------------------------------------------------------------------
# 2. An analysis that did not run is NOT a pass.
# ---------------------------------------------------------------------------
# deadcode writes findings to stdout. A gate that reads stdout only cannot tell
# "no dead code" from "analysed nothing", and an analysis error produces empty
# stdout. So the exit code is checked first and stderr is kept.
err="$(mktemp)"
out="$("$bin" ./... 2>"$err")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then
  echo "deadcode-gate: deadcode could not analyse the module (exit ${rc})." >&2
  echo "The gate found NO dead code because it read no code. Do not read this as a pass." >&2
  echo "If the error mentions a newer Go version, raise the caller's DEADCODE_VERSION." >&2
  cat "$err" >&2
  rm -f "$err"
  exit 1
fi
rm -f "$err"

# ---------------------------------------------------------------------------
# 3. Subtract the allowlist, keyed by SYMBOL.
# ---------------------------------------------------------------------------
# Keyed by the symbol deadcode names, never by file and line: a guard that needs
# re-pinning after an unrelated edit is a defect in the guard. deadcode prints
#
#   path/to/file.go:12:6: unreachable func: pkg.Thing
#
# so the key is everything after "unreachable func: ".
symbols_of() { sed -n 's/.*unreachable func: //p' | sed '/^$/d' | LC_ALL=C sort -u; }

found="$(printf '%s\n' "$out" | symbols_of)"
found_count=0
[ -n "$found" ] && found_count="$(printf '%s\n' "$found" | wc -l | tr -d ' ')"

tolerated=""
tolerated_count=0
if [ -n "$ALLOWLIST" ]; then
  if [ ! -f "$ALLOWLIST" ]; then
    echo "deadcode-gate: allowlist ${ALLOWLIST} does not exist (relative to ${DIR})." >&2
    echo "An empty baseline tolerates nothing and would fail the whole repo at once, which" >&2
    echo "reads as a broken gate. A missing file is a wiring mistake, so it says so." >&2
    exit 1
  fi
  tolerated="$(grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//' | LC_ALL=C sort -u || true)"
  [ -n "$tolerated" ] && tolerated_count="$(printf '%s\n' "$tolerated" | wc -l | tr -d ' ')"
fi

new="$(comm -23 <(printf '%s\n' "$found") <(printf '%s\n' "$tolerated") | sed '/^$/d')"
stale="$(comm -13 <(printf '%s\n' "$found") <(printf '%s\n' "$tolerated") | sed '/^$/d')"

rc=0

# ---------------------------------------------------------------------------
# 4. An allowlist entry that no longer matches a finding FAILS.
# ---------------------------------------------------------------------------
# An exemption that outlives its reason is worse than none, because it reads as
# reviewed. Same rule the vuln-allowlist input applies to advisories.
if [ -n "$stale" ]; then
  echo "deadcode-gate: ${ALLOWLIST} names symbols deadcode no longer reports:" >&2
  printf '%s\n' "$stale" | while IFS= read -r sym; do echo "  $sym" >&2; done
  echo "They are reachable again, or renamed, or gone. Remove the entries." >&2
  rc=1
fi

if [ -n "$new" ]; then
  echo "deadcode-gate: unreachable code that is not in the allowlist:" >&2
  printf '%s\n' "$out" | while IFS= read -r line; do
    sym="$(printf '%s\n' "$line" | sed -n 's/.*unreachable func: //p')"
    [ -n "$sym" ] || continue
    case "
$new
" in *"
$sym
"*) echo "  $line" >&2 ;; esac
  done
  echo "Wire it to a consumer or delete it. ADR-0094: never default to deletion." >&2
  rc=1
fi

if [ "$rc" -eq 0 ]; then
  # A COUNT, not an "OK". A bare success line cannot be told from a check that
  # measured nothing, which is how several guards in this estate passed
  # vacuously. The numbers are what a reader notices are wrong.
  echo "✅ deadcode-gate: ${found_count} unreachable func(s) found, ${tolerated_count} allowlisted, 0 new"
fi
exit $rc
