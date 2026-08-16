#!/usr/bin/env bash
# Fixture + mutation tests for scripts/runs-on-lint-scan.sh. Gates the real
# scan on every run, so a regression in the classifier fails BEFORE the guard
# starts waving violations through.
#
# Exercises the real classifier via RUNS_ON_LINT_CLASSIFY_ONLY, not a copy —
# a test that reimplements the logic it is testing proves nothing.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
scan="$here/runs-on-lint-scan.sh"
fails=0

expect() { # expect <allow|reject> <label>
  local want="$1" label="$2" got
  if RUNS_ON_LINT_CLASSIFY_ONLY=1 bash "$scan" _ "$label" >/dev/null 2>&1; then got=allow; else got=reject; fi
  if [ "$got" != "$want" ]; then
    echo "FAIL  want=$want got=$got  label='$label'"; fails=$((fails+1))
  else
    echo "ok    $want  '$label'"
  fi
}

echo "== sanctioned =="
expect allow  'ubuntu-latest'
expect allow  'ubuntu-24.04'
expect allow  'staging-ephemeral'
expect allow  'prod-ephemeral'
expect allow  '${{ inputs.env }}-ephemeral'
expect allow  '${{ matrix.env }}-ephemeral'

echo "== forbidden =="
# The removed persistent runners (ADR-0060) must never come back.
expect reject 'self-hosted'
expect reject 'workstation-setec-kvm'
expect reject 'ec2-kind-standup'
# A bare expression is unbounded — the guard cannot vouch for it.
expect reject '${{ inputs.runner }}'
expect reject '${{ inputs.env }}'
# Suffix must be the whole trailing token, not a substring.
expect reject 'ephemeral'
expect reject 'not-ephemeral-really'
# Other hosted platforms are out of scope by policy, not oversight.
expect reject 'macos-14'
expect reject 'windows-latest'

echo "== end-to-end: a forbidden label in a real workflow tree fails the scan =="
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.github/workflows"
printf 'jobs:\n  a:\n    runs-on: ubuntu-latest\n' > "$tmp/.github/workflows/ok.yml"
if bash "$scan" "$tmp" >/dev/null 2>&1; then echo "ok    clean tree passes"; else echo "FAIL  clean tree should pass"; fails=$((fails+1)); fi
printf 'jobs:\n  b:\n    runs-on: self-hosted\n' > "$tmp/.github/workflows/bad.yml"
if bash "$scan" "$tmp" >/dev/null 2>&1; then echo "FAIL  dirty tree should fail"; fails=$((fails+1)); else echo "ok    dirty tree fails"; fi

# Reach floor: a scan that finds no workflow files at all must not read as a pass.
echo "== reach floor =="
empty="$(mktemp -d)"; trap 'rm -rf "$tmp" "$empty"' EXIT
out="$(bash "$scan" "$empty" 2>&1 || true)"
case "$out" in *OK*) echo "ok    empty tree reports OK (documented: nothing to scan)";; *) echo "FAIL  unexpected: $out"; fails=$((fails+1));; esac

echo "== the scanner ignores its own checkout =="
# The reusable workflow drops this repo at <caller>/.runs-on-lint. If the scan
# did not prune it, every caller would be linting zeroroot-ai/.github — and
# would fail on reusable-test.yml's legitimate `runs-on: ${{ inputs.runs-on }}`.
selfck="$(mktemp -d)"
mkdir -p "$selfck/.github/workflows" "$selfck/.runs-on-lint/.github/workflows"
printf 'jobs:\n  a:\n    runs-on: ubuntu-latest\n' > "$selfck/.github/workflows/ok.yml"
printf 'jobs:\n  b:\n    runs-on: self-hosted\n'   > "$selfck/.runs-on-lint/.github/workflows/bad.yml"
if bash "$scan" "$selfck" >/dev/null 2>&1; then
  echo "ok    .runs-on-lint/ is pruned"
else
  echo "FAIL  scanner linted its own checkout"; fails=$((fails+1))
fi
rm -rf "$selfck"

if [ "$fails" -gt 0 ]; then echo; echo "$fails assertion(s) failed"; exit 1; fi
echo; echo "all assertions passed"
