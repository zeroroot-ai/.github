#!/usr/bin/env bash
# Mutation tests for scripts/check-required-contexts.sh (.github#277).
#
# A guard whose green is read as evidence has to be shown capable of red. Every
# assertion below perturbs one thing about a synthetic ruleset tree or its
# simulated PR check-runs and REQUIRES the guard to fail. No network, no token.
#
# The three real-world shapes that motivated the guard each get a case:
#   phantom     a context no workflow ever produces (`release-please`)
#   misnamed    bare `runs-on-lint` against a real `runs-on-lint / runs-on-lint`
#   filtered    a path-filtered check that reports on some PRs and not others
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check-required-contexts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0

# Build a synthetic ruleset tree. $1 = tree dir, remaining args = contexts.
make_tree() {
  local dir="$1"; shift
  mkdir -p "$dir/rulesets/org" "$dir/rulesets/repo" "$dir/scripts"
  cp "$GUARD" "$dir/scripts/check-required-contexts.sh"
  local ctx_json
  ctx_json="$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({context: .})')"
  jq -n --argjson c "$ctx_json" '{
    name: "t", target: "branch", enforcement: "evaluate",
    conditions: {repository_name: {include: ["alpha"]}},
    rules: [{type: "required_status_checks",
             parameters: {strict_required_status_checks_policy: false,
                          required_status_checks: $c}}]
  }' > "$dir/rulesets/org/t.json"
}

# A fake PR_CHECKS_CMD. $1 = file holding the canned "<pr>\t<ctx>" lines.
make_fetch() {
  local script="$1" data="$2"
  cat > "$script" <<EOF
#!/usr/bin/env bash
cat "$data"
EOF
  chmod +x "$script"
}

run_guard() {
  local dir="$1" fetch="$2"
  ( cd "$dir" && PR_CHECKS_CMD="$fetch" bash scripts/check-required-contexts.sh 2>&1 )
}

assert() {
  local name="$1" want="$2" dir="$3" fetch="$4" out rc
  set +e; out="$(run_guard "$dir" "$fetch")"; rc=$?; set -e
  if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then
    echo "FAIL [$name]: expected exit 0, got $rc"; echo "$out"; exit 1
  fi
  if [ "$want" = fail ] && [ "$rc" -eq 0 ]; then
    echo "FAIL [$name]: guard passed but should have failed"; echo "$out"; exit 1
  fi
  echo "  ok  $name (exit $rc)"
  pass=$((pass + 1))
  LAST_OUT="$out"
}

# ---- 1. baseline: every required context on every sampled PR -> pass --------
d="$TMP/base"; make_tree "$d" "pr-title-lint" "runs-on-lint / runs-on-lint"
printf '1\tpr-title-lint\n1\truns-on-lint / runs-on-lint\n2\tpr-title-lint\n2\truns-on-lint / runs-on-lint\n' > "$TMP/base.tsv"
make_fetch "$TMP/base.sh" "$TMP/base.tsv"
assert "baseline reachable" pass "$d" "$TMP/base.sh"

# ---- 2. phantom context: never produced -> must fail ------------------------
d="$TMP/phantom"; make_tree "$d" "pr-title-lint" "release-please"
printf '1\tpr-title-lint\n2\tpr-title-lint\n' > "$TMP/phantom.tsv"
make_fetch "$TMP/phantom.sh" "$TMP/phantom.tsv"
assert "phantom context fails" fail "$d" "$TMP/phantom.sh"
grep -q "no sampled PR produced a check by that name" <<<"$LAST_OUT" \
  || { echo "FAIL: phantom case did not name its cause"; exit 1; }

# ---- 3. misnamed context: bare vs '<caller> / <job>' -> must fail -----------
d="$TMP/name"; make_tree "$d" "runs-on-lint"
printf '1\truns-on-lint / runs-on-lint\n2\truns-on-lint / runs-on-lint\n' > "$TMP/name.tsv"
make_fetch "$TMP/name.sh" "$TMP/name.tsv"
assert "misnamed context fails" fail "$d" "$TMP/name.sh"

# ---- 4. path-filtered context: reports on some PRs only -> must fail --------
d="$TMP/filtered"; make_tree "$d" "render-contract-guard"
printf '1\trender-contract-guard\n2\trender-contract-guard\n3\tpr-title-lint\n' > "$TMP/filtered.tsv"
make_fetch "$TMP/filtered.sh" "$TMP/filtered.tsv"
assert "path-filtered context fails" fail "$d" "$TMP/filtered.sh"
grep -q "missing from 1 of the 3 PRs since it was first produced" <<<"$LAST_OUT" \
  || { echo "FAIL: filtered case did not report the ratio"; exit 1; }

# ---- 4b. pre-adoption: every miss is OLDER than the first hit -> pass -------
# The gibson-executor / zitadel-login shape. A check added last week is
# legitimately absent from PRs older than itself; failing on that makes the
# guard red on arrival, and a guard that is red on arrival gets switched off.
d="$TMP/preadopt"; make_tree "$d" "ci-required"
printf '5\tci-required\n4\tci-required\n3\tsomething-else\n1\tsomething-else\n' > "$TMP/preadopt.tsv"
make_fetch "$TMP/preadopt.sh" "$TMP/preadopt.tsv"
assert "pre-adoption misses are tolerated" pass "$d" "$TMP/preadopt.sh"
grep -q "older PR(s) predate it" <<<"$LAST_OUT" \
  || { echo "FAIL: pre-adoption case did not say why it was tolerated"; exit 1; }

# ---- 4c. the anchor is not a loophole: a miss INSIDE the window fails -------
# Same miss count as 4b, but the gap is newer than the first appearance. That
# is a path filter, and it must still be caught.
d="$TMP/inwindow"; make_tree "$d" "ci-required"
printf '5\tci-required\n4\tsomething-else\n3\tci-required\n1\tsomething-else\n' > "$TMP/inwindow.tsv"
make_fetch "$TMP/inwindow.sh" "$TMP/inwindow.tsv"
assert "a gap inside the window still fails" fail "$d" "$TMP/inwindow.sh"
grep -q "missing from 1 of the 3 PRs since it was first produced" <<<"$LAST_OUT" \
  || { echo "FAIL: in-window gap reported the wrong window"; exit 1; }

# ---- 5. reach floor: fetch returns nothing at all -> must fail --------------
# Without this the guard would report green when the sampling breaks, and a
# green here is read as "every required context is reachable".
d="$TMP/empty"; make_tree "$d" "pr-title-lint"
: > "$TMP/empty.tsv"
make_fetch "$TMP/empty.sh" "$TMP/empty.tsv"
assert "empty fetch trips the reach floor" fail "$d" "$TMP/empty.sh"
grep -q "reach floor" <<<"$LAST_OUT" \
  || { echo "FAIL: empty fetch failed for the wrong reason"; exit 1; }

# ---- 6. a ruleset with no required checks is not a failure -----------------
d="$TMP/norule"; make_tree "$d" "pr-title-lint"
jq 'del(.rules)' "$d/rulesets/org/t.json" > "$d/rulesets/org/t.tmp" && mv "$d/rulesets/org/t.tmp" "$d/rulesets/org/t.json"
jq -n '{name:"u",target:"branch",enforcement:"evaluate",
        conditions:{repository_name:{include:["alpha"]}},
        rules:[{type:"required_status_checks",
                parameters:{required_status_checks:[{context:"pr-title-lint"}]}}]}' \
  > "$d/rulesets/repo/alpha.json"
assert "rule-less ruleset is skipped, repo one still checked" pass "$d" "$TMP/base.sh"

echo
echo "OK: $pass assertions, guard proven capable of failing on all three real shapes."
