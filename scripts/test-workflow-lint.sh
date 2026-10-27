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

echo "== a job that starts kind raises the inotify limits first =="
awk '/BEGIN-KIND/{f=1;next} /END-KIND/{f=0} f' "$wf" | sed 's/^          //' > "$work/kind.py"
grep -q 'helm/kind-action' "$work/kind.py" \
  || { echo "FAIL: could not extract the kind block from $wf"; exit 1; }
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$work/kind.py" \
  || { echo "FAIL: the extracted kind block is not valid Python"; exit 1; }

# kind_tree <name> writes one workflow from stdin into a fresh tree.
kind_tree() { mkdir -p "$work/$1/.github/workflows"; cat > "$work/$1/.github/workflows/x.yml"; }
kind_run() { ( cd "$work/$1" && python3 "$work/kind.py" ) 2>&1; }
kind_red() { # kind_red <tree> <expected substring>
  local out rc=0
  out="$(kind_run "$1")" || rc=$?
  if [ "$rc" -eq 0 ]; then echo "FAIL  $1 was allowed"; fails=$((fails+1)); return; fi
  case "$out" in
    *"$2"*) echo "ok    red    $1"; passed=$((passed+1)) ;;
    *) echo "FAIL  $1 failed for the wrong reason; wanted '$2', got: $out"; fails=$((fails+1)) ;;
  esac
}
kind_green() { # kind_green <tree>
  local out rc=0
  out="$(kind_run "$1")" || rc=$?
  if [ "$rc" -ne 0 ]; then echo "FAIL  $1 was blocked: $out"; fails=$((fails+1)); else echo "ok    green  $1"; passed=$((passed+1)); fi
}
RAISE='      - uses: zeroroot-ai/.github/.github/actions/raise-inotify-limits@0123456789abcdef0123456789abcdef01234567 # v9.9.9'

# 13. THE CASES THIS STEP EXISTS FOR (gibson#1331). Each way to start kind, with
#     no raise before it, fails and names that way.
for start in 'make recreate ENV=kind' 'SUBSTRATE_DIR=/tmp/s make substrate ENV=kind' 'kind create cluster --name t --config k.yaml'; do
  name="kind-noraise-$(printf '%s' "$start" | tr -c '[:lower:]' '-' | cut -c1-30)"
  kind_tree "$name" <<YAML
on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: $start
YAML
  case "$start" in
    *recreate*) want='(make recreate ENV=kind)' ;;
    *substrate*) want='(make substrate ENV=kind)' ;;
    *) want='(kind create cluster)' ;;
  esac
  kind_red "$name" "$want"
done
kind_tree kind-action-noraise <<'YAML'
on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - uses: helm/kind-action@1544676c07bb3570fcb70166beaa07c4528fd4aa # v1.15.1
        with:
          config: hack/kind.yaml
YAML
kind_red kind-action-noraise 'helm/kind-action without install_only'
# 13b. `make recreate` of an AWS environment starts no kind cluster, so it
#      needs no raise (hosted drill.yml and recreate.yml).
kind_tree kind-recreate-aws <<'YAML'
on: push
jobs:
  t:
    runs-on: ubuntu-latest
    env:
      ENV: staging
    steps:
      - run: make recreate ENV="${ENV}" INSTANCE_TYPE=m8i.2xlarge
      - run: make recreate ENV=${ENV}
YAML
kind_green kind-recreate-aws
# 13c. A composite action named through a checkout path is read through it
#      (gibson checks out into `gibson` and names ./gibson/.github/actions/<x>).
mkdir -p "$work/kind-checkout-path/.github/actions/up"
cat > "$work/kind-checkout-path/.github/actions/up/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - shell: bash
      run: kind create cluster
YAML
kind_tree kind-checkout-path <<'YAML'
on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - uses: ./gibson/.github/actions/up
YAML
kind_red kind-checkout-path '.github/actions/up/action.yml step 1'
# 14. The raise AFTER the start does not count.
kind_tree kind-raise-after <<YAML
on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: kind create cluster
$RAISE
YAML
kind_red kind-raise-after '(kind create cluster)'
# 15. A raise in ANOTHER job does not count.
kind_tree kind-raise-other-job <<YAML
on: push
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
$RAISE
  b:
    runs-on: ubuntu-latest
    steps:
      - run: make recreate ENV=kind
YAML
kind_red kind-raise-other-job 'job b step 1'
# 16. A kind start inside a composite action of the repo is read through it.
mkdir -p "$work/kind-composite/.github/actions/up"
cat > "$work/kind-composite/.github/actions/up/action.yml" <<'YAML'
runs:
  using: composite
  steps:
    - shell: bash
      run: make substrate ENV=kind
YAML
kind_tree kind-composite <<'YAML'
on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/up
YAML
kind_red kind-composite '.github/actions/up/action.yml step 1'
# 17. Green: the raise first, then every start. install_only, the local
#     gibson copy of the action, and a start named only in a comment pass.
kind_tree kind-raised <<YAML
on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - uses: helm/kind-action@1544676c07bb3570fcb70166beaa07c4528fd4aa # v1.15.1
        with:
          install_only: true
      - run: |
          # make recreate ENV=kind creates the cluster in the next step
          echo prepare
$RAISE
      - run: SUBSTRATE_DIR=/tmp/s make substrate ENV=kind
      - run: make recreate ENV=kind
      - run: kind create cluster
  local:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/raise-inotify-limits
      - run: make recreate ENV=kind
YAML
kind_green kind-raised
# 18. This repo's own workflows pass. The kind step names every kind start in
#     its program, and it must not read itself as one (.github#307 first run).
mkdir -p "$work/kind-self/.github/workflows"
cp "$here"/../.github/workflows/*.yml "$work/kind-self/.github/workflows/"
kind_green kind-self
# 19. THE FLOOR. A tree with no workflow file checked nothing.
mkdir -p "$work/kind-empty/.github/workflows"
kind_red kind-empty 'checked nothing'

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
if [ "$fails" -eq 0 ] && [ "$passed" -lt 25 ]; then
  echo "FAIL: only $passed assertion(s) ran, want 25"; exit 1
fi
[ "$fails" -eq 0 ]
