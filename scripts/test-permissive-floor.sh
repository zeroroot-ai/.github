#!/usr/bin/env bash
# Assertions for the permissive-floor reusable workflow.
#
# The check is INLINE in .github/workflows/permissive-floor.yml, for the reason
# scripts/test-runs-on-lint.sh gives. So this test EXTRACTS the shipped block
# between its markers and runs those exact bytes against fixture trees. Each
# failing fixture must fail for its stated reason.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="$here/../.github/workflows/permissive-floor.yml"
fails=0 passed=0

block="$(awk '/BEGIN-CHECK/{f=1;next} /END-CHECK/{f=0} f' "$wf")"
# Reach floor: the extracted block must be the real check.
echo "$block" | grep -q 'PERMISSIVE="sdk adk setec ast-checks"' || { echo "FAIL: could not extract the check from $wf"; exit 1; }
echo "$block" | grep -q 'find . -name go.mod' || { echo "FAIL: the extracted block does not walk go.mod files"; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# tree <name> <relative go.mod path> <require lines>
tree() {
  mkdir -p "$work/$1/$(dirname "$2")"
  printf 'module github.com/zeroroot-ai/sdk\n\ngo 1.27.1\n\nrequire (\n%b\n)\n' "$3" > "$work/$1/$2"
}

run_check() { ( cd "$work/$1" && set -euo pipefail && eval "$block" ) 2>&1; }

red() { # red <name> <expected substring>
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

# 1. THE CASE THIS GUARD EXISTS FOR. An Apache repo requires the ELv2 daemon.
tree direct go.mod '\tgithub.com/zeroroot-ai/gibson v0.150.1'
red direct 'go.mod:6 requires github.com/zeroroot-ai/gibson, which is not on the permissive floor'

# 2. An indirect requirement is the same edge.
tree indirect go.mod '\tgithub.com/zeroroot-ai/gibson v0.150.1 // indirect'
red indirect 'requires github.com/zeroroot-ai/gibson,'

# 3. gibson-executor is Elastic License 2.0 (ADR-0089). It is named in full.
tree executor go.mod '\tgithub.com/zeroroot-ai/gibson-executor v0.90.0'
red executor 'requires github.com/zeroroot-ai/gibson-executor,'

# 4. The closed repo.
tree billing go.mod '\tgithub.com/zeroroot-ai/billing v0.1.0'
red billing 'requires github.com/zeroroot-ai/billing,'

# 5. Default deny: a first-party repo that no list names is restrictive.
tree unknown go.mod '\tgithub.com/zeroroot-ai/some-new-repo v0.1.0'
red unknown 'requires github.com/zeroroot-ai/some-new-repo,'

# 6. A sub-module of a restrictive repo.
tree submodule go.mod '\tgithub.com/zeroroot-ai/gibson/pkg/billing v0.1.0'
red submodule 'requires github.com/zeroroot-ai/gibson,'

# 7. A replace directive is a requirement too.
tree replace go.mod '\tgithub.com/zeroroot-ai/ast-checks v0.6.0\n)\n\nreplace github.com/zeroroot-ai/ast-checks => github.com/zeroroot-ai/hosted v0.1.0\n\nrequire ('
red replace 'requires github.com/zeroroot-ai/hosted,'

# 8. A second go.mod in the repository (an example, a tool) is checked.
tree nested go.mod '\tgithub.com/zeroroot-ai/ast-checks v0.6.0'
tree nested examples/tool/go.mod '\tgithub.com/zeroroot-ai/dashboard v0.1.0'
red nested 'examples/tool/go.mod:6 requires github.com/zeroroot-ai/dashboard,'

# 9. The permissive floor passes, sub-module paths included.
tree permissive go.mod '\tgithub.com/zeroroot-ai/ast-checks v0.6.0\n\tgithub.com/zeroroot-ai/sdk v0.192.2\n\tgithub.com/zeroroot-ai/adk/gibson v0.112.1\n\tgithub.com/zeroroot-ai/setec v0.118.1 // indirect'
green permissive

# 10. Prose in a comment is not a requirement.
tree comment go.mod '\tgithub.com/zeroroot-ai/ast-checks v0.6.0 // not github.com/zeroroot-ai/gibson'
green comment

# 11. A fixture under testdata is not this repository's dependency.
tree testdata go.mod '\tgithub.com/zeroroot-ai/ast-checks v0.6.0'
tree testdata internal/testdata/sample/go.mod '\tgithub.com/zeroroot-ai/gibson v0.150.1'
green testdata

# 12. THE FLOOR. A tree with no go.mod checked nothing.
mkdir -p "$work/empty"
red empty 'checked nothing'

echo "== no GitHub expression inside the run: block =="
runblock="$(awk '/- name: No go.mod requires/,0' "$wf" | awk '/run: \|/,0')"
if printf '%s' "$runblock" | grep -q '\${{'; then
  echo "FAIL  a GitHub expression appears inside the run: block"; fails=$((fails+1))
else
  echo "ok    run: block contains no interpolatable expression"; passed=$((passed+1))
fi

echo
echo "passed=$passed failed=$fails"
if [ "$fails" -eq 0 ] && [ "$passed" -lt 13 ]; then echo "FAIL: only $passed assertion(s) ran, want 13"; exit 1; fi
[ "$fails" -eq 0 ]
