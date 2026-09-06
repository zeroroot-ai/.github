#!/usr/bin/env bash
# Mutation test for scripts/check-ruleset-drift.sh.
#
# A drift guard that cannot go red is worth less than no guard at all, because
# it is read as evidence. So every assertion below is a MUTATION: it perturbs
# the simulated live state in one specific way and requires the guard to fail.
# The two pass-cases exist only to prove the guard is not failing on everything.
#
# No network, no org-admin token: the guard's live-state fetch is injected via
# RULESET_FETCH_CMD, so this runs in the pull_request lane where secrets are
# not available.
#
# Called by the `drift-guard-fixtures` job in .github/workflows/ruleset-drift.yml.
#
# Exit 0 = every assertion held. Exit 1 = at least one did not.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/check-ruleset-drift.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

# A minimal but structurally faithful repo ruleset: merge queue + required
# status checks, same shape as every rulesets/repo/*.json in this repo.
mkdir -p "${WORK}/rulesets/repo" "${WORK}/rulesets/org" "${WORK}/live"
cat > "${WORK}/rulesets/repo/fixture-repo.json" <<'EOF'
{
  "name": "fixture-repo-required-checks",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    {
      "type": "merge_queue",
      "parameters": {
        "merge_method": "SQUASH",
        "check_response_timeout_minutes": 60,
        "grouping_strategy": "ALLGREEN",
        "max_entries_to_build": 5,
        "max_entries_to_merge": 5,
        "min_entries_to_merge": 1,
        "min_entries_to_merge_wait_minutes": 5
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "ci-required" },
          { "context": "Lint (golangci-lint)" }
        ]
      }
    }
  ]
}
EOF

# The injected fetcher just cats a file named for the scope. Absent file =
# "no live ruleset by that name", which is what the real fetcher signals by
# printing nothing.
cat > "${WORK}/fetch.sh" <<'EOF'
#!/usr/bin/env bash
f="${LIVE_DIR}/$1.json"
[ -f "$f" ] || exit 1
cat "$f"
EOF
chmod +x "${WORK}/fetch.sh"

# assert <name> <pass|fail> — runs the guard against whatever is in live/ now.
assert() {
  local desc="$1" expect="$2" out rc result
  out="$(RULESET_DIR="${WORK}/rulesets" \
         RULESET_FETCH_CMD="${WORK}/fetch.sh" \
         LIVE_DIR="${WORK}/live" \
         bash "$GUARD" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then result="pass"; else result="fail"; fi

  if [ "$result" = "$expect" ]; then
    echo "✅ ${desc} → ${result} (expected ${expect})"
    PASS=$((PASS + 1))
  else
    echo "❌ ${desc} → ${result} (expected ${expect})"
    echo "$out" | sed 's/^/      /'
    FAIL=$((FAIL + 1))
  fi
}

# live_from <jq-filter> — writes the fixture through a jq filter into live/,
# simulating the API's echo of a (possibly drifted) live ruleset.
live_from() {
  jq "$1" "${WORK}/rulesets/repo/fixture-repo.json" > "${WORK}/live/repo.json"
}

# ---------------------------------------------------------------------------
# Control 1: identical live state passes.
# ---------------------------------------------------------------------------
live_from '.'
assert "live identical to file" pass

# ---------------------------------------------------------------------------
# Control 2: the API's non-semantic noise must NOT read as drift. If it did,
# the guard would be permanently red and would get disabled within a day.
#   - server-populated fields we never author
#   - reordered rules and reordered required_status_checks
# ---------------------------------------------------------------------------
live_from '
  . + {id: 18136475, node_id: "RRS_x", created_at: "2026-01-01T00:00:00Z",
       updated_at: "2026-08-15T00:00:00Z", source: "zeroroot-ai/fixture-repo",
       source_type: "Repository", current_user_can_bypass: "always",
       _links: {self: {href: "https://api.github.com/x"}}}
  | .rules |= reverse
  | (.rules[] | select(.type=="required_status_checks")
      | .parameters.required_status_checks) |= reverse
'
assert "server-added fields + reordered arrays" pass

# ---------------------------------------------------------------------------
# Control 3: server-DEFAULTED parameter keys inside a rule must not read as
# drift either. This is not hypothetical — the API returns `pull_request` rules
# carrying `dismissal_restriction` and `required_reviewers`, which appear in no
# committed file in this repo. Byte-equality flagged all five such repos.
# ---------------------------------------------------------------------------
live_from '
  (.rules[] | select(.type=="merge_queue") | .parameters) +=
    {"some_future_server_default": false}
'
assert "server-defaulted parameter key the file never declares" pass

# ---------------------------------------------------------------------------
# MUTATION 1 — the .github#264 case exactly: a required check exists live but
# not in the file. Direction matters; this is the one that gets silently
# reverted by the next apply, so it must be caught even though live is
# STRICTER than the file.
# ---------------------------------------------------------------------------
live_from '
  (.rules[] | select(.type=="required_status_checks")
    | .parameters.required_status_checks) += [{"context": "Analyze Go"}]
'
assert "MUTATION live has an extra required check (#264 direction)" fail

# ---------------------------------------------------------------------------
# MUTATION 2 — a required check in the file is missing live. This is the
# "committed gate is not actually in force" direction.
# ---------------------------------------------------------------------------
live_from '
  (.rules[] | select(.type=="required_status_checks")
    | .parameters.required_status_checks) |= map(select(.context != "ci-required"))
'
assert "MUTATION live is missing a required check" fail

# ---------------------------------------------------------------------------
# MUTATION 3 — a required context renamed live. Same count, so any check that
# only compared list LENGTH would pass this.
# ---------------------------------------------------------------------------
live_from '
  (.rules[] | select(.type=="required_status_checks")
    | .parameters.required_status_checks) |=
      map(if .context == "ci-required" then {"context": "ci-requiredX"} else . end)
'
assert "MUTATION required context renamed live" fail

# ---------------------------------------------------------------------------
# MUTATION 4 — enforcement downgraded to "evaluate". A ruleset in evaluate mode
# reports on the PR and blocks nothing, so this is a gate silently switched off
# with every context still listed.
# ---------------------------------------------------------------------------
live_from '.enforcement = "evaluate"'
assert "MUTATION enforcement downgraded to evaluate" fail

# ---------------------------------------------------------------------------
# MUTATION 5 — the whole required_status_checks rule removed live (the
# "emergency edit to unfreeze the queue" that never got reverted).
# ---------------------------------------------------------------------------
live_from '.rules |= map(select(.type != "required_status_checks"))'
assert "MUTATION required_status_checks rule dropped live" fail

# ---------------------------------------------------------------------------
# MUTATION 6 — merge-queue grouping strategy changed live.
# ---------------------------------------------------------------------------
live_from '(.rules[] | select(.type=="merge_queue") | .parameters.grouping_strategy) = "HEADGREEN"'
assert "MUTATION merge_queue parameter changed live" fail

# ---------------------------------------------------------------------------
# MUTATION 7 — a bypass actor added live. Anyone who can bypass makes every
# required check optional for them; a drift check that ignored this would call
# a bypassable ruleset "in force".
# ---------------------------------------------------------------------------
live_from '.bypass_actors = [{"actor_id": 1, "actor_type": "OrganizationAdmin", "bypass_mode": "always"}]'
assert "MUTATION bypass actor added live" fail

# ---------------------------------------------------------------------------
# MUTATION 8 — no live ruleset at all (the `gitops` condition: committed file,
# nothing in force). "Absent" must not be read as "nothing to compare".
# ---------------------------------------------------------------------------
rm -f "${WORK}/live/repo.json"
assert "MUTATION no live ruleset exists" fail

# ---------------------------------------------------------------------------
# MUTATION 9 — an empty rulesets dir must not report green. Guards that walk a
# glob report success on zero iterations, which turns a bad path or a moved
# directory into a permanent pass.
# ---------------------------------------------------------------------------
live_from '.'
EMPTY="$(mktemp -d)"
mkdir -p "${EMPTY}/org" "${EMPTY}/repo"
out="$(RULESET_DIR="$EMPTY" RULESET_FETCH_CMD="${WORK}/fetch.sh" LIVE_DIR="${WORK}/live" \
       bash "$GUARD" 2>&1)"
if [ $? -ne 0 ]; then
  echo "✅ MUTATION empty ruleset dir → fail (expected fail)"
  PASS=$((PASS + 1))
else
  echo "❌ MUTATION empty ruleset dir → pass (expected fail)"
  echo "$out" | sed 's/^/      /'
  FAIL=$((FAIL + 1))
fi
rm -rf "$EMPTY"

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[ "$FAIL" -eq 0 ]
