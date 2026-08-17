#!/usr/bin/env bash
# Required-context reachability guard — does every context a ruleset REQUIRES
# actually get produced on a pull request in the repos that ruleset targets?
#
# Why this exists (.github#277)
# -----------------------------
# A required status check that nobody produces is not a gate. It is a permanent
# block. GitHub evaluates required contexts against the PR head sha, and a
# context that never appears there is "expected" forever, so the PR can never
# become mergeable.
#
# While a ruleset sits at enforcement=evaluate this is invisible: the contexts
# are recorded and nothing acts on them. The defect only surfaces at the moment
# someone flips enforcement to active — which is the worst possible moment,
# because the flip is now indistinguishable from an outage.
#
# Measured on 2026-08-17, before this guard existed, over the last 6 merged PRs
# in each targeted repo:
#
#   tier-core         required 4 contexts. THREE never reported in ANY of its
#                     five repos: `release-please` (runs on push to main, never
#                     on a PR), `no-monorepo-shortcuts` and `runs-on-lint`
#                     (real check-run names are `X / X` — they are called
#                     through the policy-guards reusable workflow, so the check
#                     name is "<caller job> / <called job>").
#   tier-opensource   required 4 contexts. NOT ONE reported anywhere.
#                     `Scorecard analysis` runs on schedule and push, never on
#                     a PR; sdk-ts and zerocool-plugins have no pr-title-lint
#                     workflow at all.
#   gitops.json       required `terraform`, which has no workflow in that repo,
#                     and `check-tenant-id-label` / `promotion-isolation-guard`,
#                     which are filtered to `envs/**` and therefore absent from
#                     any PR that touches only `scripts/` or `.github/`.
#
# Three distinct causes, one symptom, none of them visible by reading the
# ruleset file. The file is valid JSON naming plausible strings. Only a real
# PR's check-run names settle it, which is what this script reads.
#
# What it asserts
# ---------------
# For each rulesets/{org,repo}/*.json, for each repo that ruleset targets, for
# each required context: the context appeared on EVERY sampled merged PR in
# that repo.
#
# EVERY, not "at least one", and that strictness is the point. A context that
# appears on some PRs and not others is path-filtered. Requiring it blocks the
# PRs it skips — deploy#1521's class, arriving through the ruleset source
# instead of through the workflow file. "Sometimes reports" is a failure here.
#
# With one exception, which the first live run earned. `ci-required` on
# gibson-executor reported on 5 of 6 sampled PRs, and the miss was #373, opened
# before that job existed. A check added last week is legitimately absent from
# PRs older than itself — that is deploy#1587's class, not a path filter. So
# the window is anchored: find the OLDEST sampled PR that produced the context,
# and require it on every PR from there forward. Misses older than the first
# appearance are pre-adoption and downgrade to a warning; a miss anywhere
# inside the window is still a failure. PR numbers are monotonic, so they order
# the sample without a second API field.
#
# A repo with no sampled PRs is reported as UNVERIFIED and skipped, because a
# new repo has no evidence either way and a guard that is red on arrival gets
# switched off. That skip is bounded by the reach floor below.
#
# Reach floor
# -----------
# If the whole run verifies zero contexts, it FAILS. Without that, a fetch that
# silently returns nothing — an expired token, a renamed flag, an API blip —
# produces a green run that reads as "every required context is reachable".
# That is the guard-that-cannot-fail class this org has hit six times.
#
# Testability
# -----------
# The PR-check fetch is injectable, so the behaviour contract is mutation-
# tested offline with no token — see scripts/test-required-contexts.sh, which
# is what the pull_request lane runs.
#
#   PR_CHECKS_CMD  invoked as: $PR_CHECKS_CMD <repo>
#                  Must print one line per (PR, check) pair:
#                      <pr-number><TAB><check-run name>
#                  Print nothing if the repo has no merged PRs to sample.
#                  Default: sample via `gh`.
#
#   SAMPLE_SIZE    merged PRs to sample per repo (default 6).
#
# Exit 0 = every required context is reachable. Exit 1 = at least one is not.
set -euo pipefail

ORG="${ORG:-zeroroot-ai}"
SAMPLE_SIZE="${SAMPLE_SIZE:-6}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

default_pr_checks() {
  local repo="$1" n
  for n in $(gh pr list -R "$ORG/$repo" --state merged --limit "$SAMPLE_SIZE" \
               --json number --jq '.[].number' 2>/dev/null); do
    gh pr view "$n" -R "$ORG/$repo" --json statusCheckRollup \
      --jq '[.statusCheckRollup[] | (.name // .context)] | unique | .[]' 2>/dev/null \
      | while IFS= read -r ctx; do printf '%s\t%s\n' "$n" "$ctx"; done
  done
}

PR_CHECKS_CMD="${PR_CHECKS_CMD:-default_pr_checks}"

# Repos a ruleset file targets. A repo-scoped file targets its own basename; an
# org-scoped file targets its conditions.repository_name.include list.
target_repos() {
  local file="$1"
  case "$file" in
    */rulesets/repo/*) basename "$file" .json ;;
    *) jq -r '.conditions.repository_name.include[]? | select(startswith("~") | not)' "$file" ;;
  esac
}

required_contexts() {
  jq -r '[.rules[]? | select(.type == "required_status_checks")
          | .parameters.required_status_checks[].context] | .[]' "$1"
}

verified=0
failures=0

for file in "$ROOT"/rulesets/org/*.json "$ROOT"/rulesets/repo/*.json; do
  [ -e "$file" ] || continue
  rel="${file#"$ROOT"/}"

  mapfile -t contexts < <(required_contexts "$file")
  [ "${#contexts[@]}" -gt 0 ] || continue

  while read -r repo; do
    [ -n "$repo" ] || continue

    checks="$($PR_CHECKS_CMD "$repo" || true)"
    all_prs="$(printf '%s\n' "$checks" | awk 'NF {print $1}' | sort -un)"
    total="$(printf '%s\n' "$all_prs" | grep -c . || true)"

    if [ "$total" -eq 0 ]; then
      echo "::warning::$rel -> $repo: no merged PRs sampled, required contexts UNVERIFIED"
      continue
    fi

    for ctx in "${contexts[@]}"; do
      hits="$(printf '%s\n' "$checks" | awk -F'\t' -v c="$ctx" '$2 == c {print $1}' | sort -un)"
      nhits="$(printf '%s\n' "$hits" | grep -c . || true)"
      verified=$((verified + 1))

      if [ "$nhits" -eq 0 ]; then
        failures=$((failures + 1))
        printf '  FAIL  %-46s %-18s 0/%s\n' "$ctx" "$repo" "$total"
        echo "::error::$rel requires '$ctx' on $repo, but no sampled PR produced a check by that name. A required context nobody produces blocks every PR once enforcement is active."
        continue
      fi

      # Anchor at the oldest PR that produced it: everything newer must have it
      # too. Older misses are pre-adoption, not a path filter.
      first="$(printf '%s\n' "$hits" | head -1)"
      window="$(printf '%s\n' "$all_prs" | awk -v f="$first" '$1 >= f' | grep -c . || true)"
      inwin="$(printf '%s\n' "$hits" | awk -v f="$first" '$1 >= f' | grep -c . || true)"

      if [ "$inwin" -ne "$window" ]; then
        failures=$((failures + 1))
        printf '  FAIL  %-46s %-18s %s/%s\n' "$ctx" "$repo" "$inwin" "$window"
        echo "::error::$rel requires '$ctx' on $repo, but it is missing from $((window - inwin)) of the $window PRs since it was first produced. A check that skips some PRs cannot be required: it blocks every PR it skips."
      elif [ "$window" -lt "$total" ]; then
        printf '  ok*   %-46s %-18s %s/%s (first seen at #%s; %s older PR(s) predate it)\n' \
          "$ctx" "$repo" "$inwin" "$window" "$first" "$((total - window))"
      else
        printf '  ok    %-46s %-18s %s/%s\n' "$ctx" "$repo" "$inwin" "$window"
      fi
    done
  done < <(target_repos "$file")
done

if [ "$verified" -eq 0 ]; then
  echo "::error::reach floor: zero required contexts were verified. The fetch returned nothing for every repo, so a green result here would be meaningless."
  exit 1
fi

if [ "$failures" -gt 0 ]; then
  echo "FAIL: $failures unreachable required context(s) of $verified checked."
  exit 1
fi

echo "OK: $verified required context(s) checked, all reachable on every sampled PR."
