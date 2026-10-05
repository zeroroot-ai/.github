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

GOOD=$'on:\n  push:\n    branches: [main]\n  schedule:\n    - cron: "0 4 * * *"\n  workflow_dispatch: {}'

# 1. The three triggers of the rule.
wf_file clean exit-test-a.yml "$GOOD"
green clean

# 2. THE CASE THIS GUARD EXISTS FOR.
wf_file pr exit-test-a.yml $'on:\n  pull_request:\n  schedule:\n    - cron: "0 4 * * *"\n  workflow_dispatch: {}'
red pr 'exit-test-a.yml: has a `pull_request` trigger'

# 3. pull_request_target and merge_group are the pull request lane too.
wf_file prt exit-test-a.yml $'on:\n  pull_request_target:\n  schedule:\n    - cron: "0 4 * * *"'
red prt 'has a `pull_request_target` trigger'
wf_file mq exit-test-a.yml $'on:\n  merge_group:\n  schedule:\n    - cron: "0 4 * * *"'
red mq 'has a `merge_group` trigger'

# 4. The list form of `on:` is read as well as the map form.
wf_file listform exit-test-a.yml 'on: [push, pull_request, schedule]'
red listform 'has a `pull_request` trigger'

# 5. One bad file among good ones still fails, and is named.
wf_file mixed exit-test-a.yml "$GOOD"
wf_file mixed exit-test-b.yaml $'on:\n  pull_request:\n  schedule:\n    - cron: "0 4 * * *"'
red mixed 'exit-test-b.yaml: has a `pull_request` trigger'

# 6. No schedule: a test that only a person can start.
wf_file nosched exit-test-a.yml $'on:\n  workflow_dispatch: {}'
red nosched 'exit-test-a.yml: has no `schedule` trigger'

# 7. The schedule rule takes an exemption with a reason.
wf_file exempt exit-test-a.yml $'on:\n  workflow_dispatch: {}'
printf '# why: needs a paid substrate, started by hand before a release\n.github/workflows/exit-test-a.yml\n' > "$work/exempt/.exit-tests-no-schedule"
green exempt

# 8. An exemption with no reason is refused.
wf_file noreason exit-test-a.yml $'on:\n  workflow_dispatch: {}'
printf '.github/workflows/exit-test-a.yml\n' > "$work/noreason/.exit-tests-no-schedule"
red noreason 'has no `# why:` line above it'

# 9. An exemption cannot cover the pull request rule.
wf_file exemptpr exit-test-a.yml $'on:\n  pull_request:\n  workflow_dispatch: {}'
printf '# why: tried to exempt a pull request trigger\n.github/workflows/exit-test-a.yml\n' > "$work/exemptpr/.exit-tests-no-schedule"
red exemptpr 'has a `pull_request` trigger'

# 10. A stale exemption fails: the file is gone, or it has a schedule now.
wf_file stalegone exit-test-a.yml "$GOOD"
printf '# why: old\n.github/workflows/exit-test-gone.yml\n' > "$work/stalegone/.exit-tests-no-schedule"
red stalegone 'names no exit-test workflow'
wf_file stalesched exit-test-a.yml "$GOOD"
printf '# why: old\n.github/workflows/exit-test-a.yml\n' > "$work/stalesched/.exit-tests-no-schedule"
red stalesched 'has a `schedule` trigger now'

# 11. A workflow that is not an exit test is not this guard's business.
wf_file other exit-test-a.yml "$GOOD"
wf_file other ci.yml $'on:\n  pull_request:'
green other

# 12. THE FLOOR. A repo with no exit-test workflow checked nothing.
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
if [ "$fails" -eq 0 ] && [ "$passed" -lt 15 ]; then echo "FAIL: only $passed assertion(s) ran, want 15"; exit 1; fi
[ "$fails" -eq 0 ]
