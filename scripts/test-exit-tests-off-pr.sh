#!/usr/bin/env bash
# Assertions for the exit-tests-off-pr reusable workflow.
#
# The check is an INLINE Python program in
# .github/workflows/exit-tests-off-pr.yml, for the reason
# scripts/test-runs-on-lint.sh gives. This test EXTRACTS the shipped program
# between its markers and runs those exact bytes against fixture trees. Each
# failing fixture must fail for its stated reason.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="$here/../.github/workflows/exit-tests-off-pr.yml"
fails=0 passed=0

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# The program sits ten columns deep in the YAML block scalar.
awk '/BEGIN-CHECK/{f=1;next} /END-CHECK/{f=0} f' "$wf" | sed 's/^          //' > "$work/check.py"
grep -q 'PR_LANE = ("pull_request", "pull_request_target", "merge_group")' "$work/check.py" \
  || { echo "FAIL: could not extract the check from $wf"; exit 1; }
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$work/check.py" \
  || { echo "FAIL: the extracted check is not valid Python"; exit 1; }

# wf_file <tree> <file name> <on block>
wf_file() {
  mkdir -p "$work/$1/.github/workflows"
  printf 'name: x\n%s\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n' "$3" > "$work/$1/.github/workflows/$2"
}
run_check() { ( cd "$work/$1" && python3 "$work/check.py" ) 2>&1; }

red() { # red <tree> <expected substring>
  local out rc=0
  out="$(run_check "$1")" || rc=$?
  if [ "$rc" -eq 0 ]; then echo "FAIL  $1 was allowed"; fails=$((fails+1)); return; fi
  case "$out" in
    *"$2"*) echo "ok    red    $1"; passed=$((passed+1)) ;;
    *) echo "FAIL  $1 failed for the wrong reason; wanted '$2', got: $out"; fails=$((fails+1)) ;;
  esac
}
green() {
  local out rc=0
  out="$(run_check "$1")" || rc=$?
  if [ "$rc" -ne 0 ]; then echo "FAIL  $1 was blocked: $out"; fails=$((fails+1)); else echo "ok    green  $1"; passed=$((passed+1)); fi
}

GOOD=$'on:\n  push:\n    branches: [main]\n  workflow_dispatch: {}'

# 1. A clean exit test.
wf_file clean exit-test-a.yml "$GOOD"
green clean

# 2. THE CASE THIS GUARD EXISTS FOR.
wf_file pr exit-test-a.yml $'on:\n  pull_request:\n  workflow_dispatch: {}'
red pr 'exit-test-a.yml: has a `pull_request` trigger'

# 3. pull_request_target and merge_group are the pull request lane too.
wf_file prt exit-test-a.yml $'on:\n  pull_request_target:'
red prt 'has a `pull_request_target` trigger'
wf_file mq exit-test-a.yml $'on:\n  merge_group:'
red mq 'has a `merge_group` trigger'

# 4. The list form of `on:` is read as well as the map form.
wf_file listform exit-test-a.yml 'on: [push, pull_request]'
red listform 'has a `pull_request` trigger'

# 5. One bad file among good ones still fails, and is named.
wf_file mixed exit-test-a.yml "$GOOD"
wf_file mixed exit-test-b.yaml $'on:\n  pull_request:'
red mixed 'exit-test-b.yaml: has a `pull_request` trigger'

# 6. A workflow that is not an exit test is not this guard's business.
wf_file other exit-test-a.yml "$GOOD"
wf_file other ci.yml $'on:\n  pull_request:'
green other

# 7. THE FLOOR. A repo with no exit-test workflow checked nothing.
wf_file empty ci.yml $'on:\n  pull_request:'
red empty 'checked nothing'

echo "== no GitHub expression inside the run: block =="
runblock="$(awk '/- name: No exit test runs on a pull request/,0' "$wf" | awk '/run: \|/,0')"
if printf '%s' "$runblock" | grep -q '\${{'; then
  echo "FAIL  a GitHub expression appears inside the run: block"; fails=$((fails+1))
else
  echo "ok    run: block contains no interpolatable expression"; passed=$((passed+1))
fi

echo
echo "passed=$passed failed=$fails"
if [ "$fails" -eq 0 ] && [ "$passed" -lt 9 ]; then echo "FAIL: only $passed assertion(s) ran, want 9"; exit 1; fi
[ "$fails" -eq 0 ]
