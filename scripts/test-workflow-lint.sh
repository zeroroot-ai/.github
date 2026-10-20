#!/usr/bin/env bash
# Assertions for the workflow-lint reusable workflow.
#
# The lint is INLINE in .github/workflows/workflow-lint.yml, for the reason
# scripts/test-runs-on-lint.sh gives. So this test EXTRACTS the shipped
# install and lint blocks between their markers and runs those exact bytes
# against fixture repositories. Each failing fixture must fail for its stated
# reason, not merely fail.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="$here/../.github/workflows/workflow-lint.yml"
fails=0 passed=0

install_block="$(awk '/BEGIN-INSTALL/{f=1;next} /END-INSTALL/{f=0} f' "$wf")"
lint_block="$(awk '/BEGIN-LINT/{f=1;next} /END-LINT/{f=0} f' "$wf")"
# Reach floor: the extracted blocks must be the real ones, not whitespace that
# passes every assertion.
echo "$install_block" | grep -q 'ACTIONLINT_SHA256=' || { echo "FAIL: could not extract the install block from $wf"; exit 1; }
echo "$lint_block" | grep -q '"\$tools/actionlint" -config-file' || { echo "FAIL: could not extract the lint block from $wf"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
export RUNNER_TEMP="$work/runner"
mkdir -p "$RUNNER_TEMP"
( set -euo pipefail; eval "$install_block" )
tools="${RUNNER_TEMP}/workflow-lint"

# fixture <name> writes one workflow file from stdin into a fresh repository.
fixture() {
  local dir="$work/$1"
  mkdir -p "$dir/.github/workflows"
  git -C "$dir" init -q .
  cat > "$dir/.github/workflows/fixture.yml"
}

# run_lint <name> prints the lint output and returns its exit code.
run_lint() {
  ( cd "$work/$1" && set -euo pipefail && tools="$tools" && eval "$lint_block" ) 2>&1
}

red() { # red <name> <expected substring>
  local out rc=0
  out="$(run_lint "$1")" || rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "FAIL  $1 was allowed"; fails=$((fails+1)); return
  fi
  case "$out" in
    *"$2"*) echo "ok    red    $1"; passed=$((passed+1)) ;;
    *) echo "FAIL  $1 failed for the wrong reason; wanted '$2', got: $out"; fails=$((fails+1)) ;;
  esac
}

green() { # green <name>
  local out rc=0
  out="$(run_lint "$1")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL  $1 was blocked: $out"; fails=$((fails+1))
  else
    echo "ok    green  $1"; passed=$((passed+1))
  fi
}

# 1. THE CASE THIS GUARD EXISTS FOR (setec#147). A job output reads a step id
#    that no step has. GitHub evaluates it to an empty string.
fixture undefined-step <<'YAML'
name: fixture
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      kata_version: ${{ steps.kata.outputs.version }}
    steps:
      - id: pins
        run: echo "version=1" >> "$GITHUB_OUTPUT"
YAML
red undefined-step 'property "kata" is not defined'

# 2. A context that does not exist where it is used (the charts case). The run
#    fails at dispatch with zero jobs and no log.
fixture context-not-allowed <<'YAML'
name: fixture
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      DIR: ${{ runner.temp }}/x
    steps:
      - run: echo ok
YAML
red context-not-allowed 'context "runner" is not allowed here'

# 3. A `needs` that names a job that does not exist.
fixture unknown-needs <<'YAML'
name: fixture
on:
  push:
    branches: [main]
jobs:
  test:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - run: echo ok
YAML
red unknown-needs 'needs job "build" which does not exist'

# 4. A matrix key that no matrix row sets.
fixture unknown-matrix-key <<'YAML'
name: fixture
on:
  push:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        include:
          - consumer: a
    steps:
      - run: echo "$X"
        env:
          X: ${{ matrix.extra }}
YAML
red unknown-matrix-key 'property "extra" is not defined'

# 5. A persistent self-hosted label is unknown to the lint. runs-on-lint.yml
#    owns that policy; this proves the config did not widen it.
fixture unknown-runner <<'YAML'
name: fixture
on:
  push:
    branches: [main]
jobs:
  test:
    runs-on: workstation-kvm
    steps:
      - run: echo ok
YAML
red unknown-runner 'label "workstation-kvm" is unknown'

# 6. A valid workflow passes, with the org's ephemeral ARC label and with a
#    shell style finding that shellcheck would report. Style is not this gate.
fixture valid <<'YAML'
name: fixture
on:
  push:
    branches: [main]
jobs:
  build:
    runs-on: staging-ephemeral
    outputs:
      version: ${{ steps.pins.outputs.version }}
    steps:
      - id: pins
        run: |
          echo "version=1" >> $GITHUB_OUTPUT
          echo "again=2" >> $GITHUB_OUTPUT
  test:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ needs.build.outputs.version }}"
YAML
green valid

# 7. THE FLOOR. A repository with no workflow file linted nothing, and must not
#    report ok.
mkdir -p "$work/empty/.github/workflows"; git -C "$work/empty" init -q .
red empty 'linted nothing'

echo "== no-schedule step =="
# The program sits ten columns deep in the YAML block scalar.
awk '/BEGIN-NOSCHED/{f=1;next} /END-NOSCHED/{f=0} f' "$wf" | sed 's/^          //' > "$work/nosched.py"
grep -q 'glob.glob(".github/workflows/\*.yml")' "$work/nosched.py" \
  || { echo "FAIL: could not extract the no-schedule check from $wf"; exit 1; }
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$work/nosched.py" \
  || { echo "FAIL: the extracted no-schedule check is not valid Python"; exit 1; }

# nosched_tree <name> <on block> writes one workflow into a fresh tree.
nosched_tree() {
  mkdir -p "$work/$1/.github/workflows"
  printf 'name: x\n%s\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ok\n' "$2" > "$work/$1/.github/workflows/x.yml"
}
nosched_run() { ( cd "$work/$1" && python3 "$work/nosched.py" ) 2>&1; }
nosched_red() { # nosched_red <tree> <expected substring>
  local out rc=0
  out="$(nosched_run "$1")" || rc=$?
  if [ "$rc" -eq 0 ]; then echo "FAIL  $1 was allowed"; fails=$((fails+1)); return; fi
  case "$out" in
    *"$2"*) echo "ok    red    $1"; passed=$((passed+1)) ;;
    *) echo "FAIL  $1 failed for the wrong reason; wanted '$2', got: $out"; fails=$((fails+1)) ;;
  esac
}

# 8. THE CASE THIS STEP EXISTS FOR. A workflow with a schedule must fail.
nosched_tree sched $'on:\n  schedule:\n    - cron: "0 4 * * *"\n  workflow_dispatch: {}'
nosched_red sched 'x.yml: has a `schedule` trigger'
# 9. The list form of `on:` is read as well as the map form.
nosched_tree schedlist 'on: [push, schedule]'
nosched_red schedlist 'has a `schedule` trigger'
# 10. A workflow with no schedule passes.
nosched_tree nosched $'on:\n  push:\n    branches: [main]\n  workflow_dispatch: {}'
if out="$(nosched_run nosched)"; then echo "ok    green  nosched"; passed=$((passed+1)); else echo "FAIL  nosched was blocked: $out"; fails=$((fails+1)); fi
# 11. A quoted "on" key cannot hide a bare on key that holds a schedule.
nosched_tree schedtwokeys $'"on": push\non:\n  schedule:\n    - cron: "0 4 * * *"'
nosched_red schedtwokeys 'has both a quoted and a bare on key'
# 12. THE FLOOR. A tree with no workflow file checked nothing.
mkdir -p "$work/nosched-empty/.github/workflows"
nosched_red nosched-empty 'checked nothing'

echo "== no GitHub expression inside the run: block =="
# Actions interpolates a dollar-two-brace expression even inside a shell
# comment in a run: block, and the whole workflow file is then invalid for
# every caller.
runblock="$(awk '/- name: Lint every workflow file/,0' "$wf" | awk '/run: \|/,0')"
if printf '%s' "$runblock" | grep -q '\${{'; then
  echo "FAIL  a GitHub expression appears inside the run: block"; fails=$((fails+1))
else
  echo "ok    run: block contains no interpolatable expression"; passed=$((passed+1))
fi

echo
echo "passed=$passed failed=$fails"
# A count floor, so cases added below this block cannot silently never run.
if [ "$fails" -eq 0 ] && [ "$passed" -lt 13 ]; then
  echo "FAIL: only $passed assertion(s) ran, want 13"; exit 1
fi
[ "$fails" -eq 0 ]
