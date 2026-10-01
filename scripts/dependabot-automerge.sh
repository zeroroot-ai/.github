#!/usr/bin/env bash
# dependabot-automerge.sh — arm auto-merge on every open Dependabot PR in the org.
#
# The owner's standing preference is to be on the latest of everything. Before
# this, every Dependabot PR waited for somebody to merge it by hand, and 74
# had piled up across 13 repos — some of them months of bumps behind.
#
# What "auto-merge" means here, exactly: `gh pr merge --auto` asks GitHub to
# merge the PR WHEN ITS REQUIRED CHECKS PASS. It does not merge anything now,
# it cannot merge a red PR, and it cannot bypass a ruleset. The merge gate
# stays the only thing deciding what lands — this just removes the human from
# the happy path. A PR that goes red simply sits there, armed, until the bump
# is fixed or closed.
#
# A repo with `allow_auto_merge: false` refuses the call outright, which is
# why repo-settings/merge.json declares it and the drift guard checks it. It
# was off on eight of sixteen repos.
#
# Policy lives in repo-settings/automerge.json, not here.
#
#   dependabot-automerge.sh             arm every eligible PR
#   dependabot-automerge.sh --dry-run   print what it would arm, change nothing
#   dependabot-automerge.sh --selftest  prove the eligibility rules
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORG="${ORG:-zeroroot-ai}"
POLICY="${AUTOMERGE_POLICY:-${HERE}/../repo-settings/automerge.json}"
DRY_RUN=0

# dependency_of <pr title> — the package a Dependabot PR bumps, lower-cased.
# Dependabot's subject is "chore(deps): bump <dep> from X to Y[ in /dir]" and
# the capitalisation of "bump" follows the repo's last commit, so both are
# matched. A grouped PR ("bump the patch-and-minor group with 3 updates")
# yields the group name, which is what an exclude entry would have to name.
dependency_of() {
  printf '%s' "$1" \
    | sed -E 's/^[^:]*: *[Bb]ump +//; s/ +from +.*$//; s/ +to +.*$//; s/ +in +\/.*$//' \
    | tr '[:upper:]' '[:lower:]'
}

# excluded <list-json> <value> — whole-string, case-insensitive membership.
excluded() {
  local list="$1" value="$2"
  printf '%s' "$list" | jq -e --arg v "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" \
    'any(.[]; (. | ascii_downcase) == $v)' >/dev/null 2>&1
}

# eligible <repo> <title> — exit 0 when this PR should be armed.
eligible() {
  local repo="$1" title="$2"
  local ex_repos ex_deps
  ex_repos=$(jq -c '.exclude_repos // []' "$POLICY")
  ex_deps=$(jq -c '.exclude_dependencies // []' "$POLICY")
  excluded "$ex_repos" "$repo" && return 1
  excluded "$ex_deps" "$(dependency_of "$title")" && return 1
  return 0
}

# arm <repo> <number> — prints its outcome: armed | already | failed.
#
# On a merge-queue repo the squash strategy is set by the queue and
# `--auto --squash` is refused, so the plain `--auto` is the fallback. Both
# print "already queued to merge" and exit 0 for a PR that is already in the
# queue, which is the only way to tell that case apart: `autoMergeRequest`
# reads null for a QUEUED pull request, so the API cannot distinguish a
# queued PR from an unarmed one.
arm() {
  local repo="$1" number="$2" out
  if [ -n "${AUTOMERGE_ARM_CMD:-}" ]; then eval "$AUTOMERGE_ARM_CMD"; return 0; fi
  # A dry run cannot tell "unarmed" from "queued": the only thing that
  # reports the difference is the merge call itself, and a QUEUED pull
  # request reads autoMergeRequest: null. So --dry-run counts every
  # not-true PR as one it would arm, which is an upper bound, not a count of
  # work to do.
  if [ "$DRY_RUN" = 1 ]; then echo armed; return 0; fi
  out=$(gh pr merge "$number" -R "${ORG}/${repo}" --auto --squash 2>&1) \
    || out=$(gh pr merge "$number" -R "${ORG}/${repo}" --auto 2>&1) \
    || { echo failed; return 0; }
  case "$out" in
    *"already queued to merge"*|*"already enabled"*) echo already ;;
    *) echo armed ;;
  esac
}

sweep() {
  if [ "$(jq -r '.enabled' "$POLICY")" != "true" ]; then
    echo "::notice::auto-merge is disabled in $(basename "$POLICY") — nothing armed"
    return 0
  fi

  local armed=0 skipped=0 already=0 failed=0 seen=0 outcome
  while IFS=$'\t' read -r repo number title auto; do
    [ -n "${repo:-}" ] || continue
    seen=$((seen + 1))
    # `auto` is authoritative only when true. A QUEUED pull request reports
    # autoMergeRequest: null, so a false here means "unarmed OR queued" and
    # arm() settles which.
    if [ "$auto" = "true" ]; then
      already=$((already + 1)); continue
    fi
    if ! eligible "$repo" "$title"; then
      echo "skip     ${repo}#${number} — excluded by policy"
      skipped=$((skipped + 1)); continue
    fi
    outcome=$(arm "$repo" "$number")
    case "$outcome" in
      armed)
        echo "armed    ${repo}#${number}  ${title}"
        armed=$((armed + 1)) ;;
      already)
        already=$((already + 1)) ;;
      *)
        echo "::warning::could not arm ${repo}#${number} — check allow_auto_merge and the branch protection on ${repo}"
        failed=$((failed + 1)) ;;
    esac
  done < <(open_dependabot_prs)

  echo
  if [ "$DRY_RUN" = 1 ]; then
    echo "${seen} open Dependabot PR(s): ${armed} would be armed (upper bound: a queued PR is indistinguishable here), ${already} already armed, ${skipped} excluded"
  else
    echo "${seen} open Dependabot PR(s): ${armed} armed, ${already} already armed, ${skipped} excluded, ${failed} refused"
  fi
  # A refusal is a real condition worth a red run: it means a repo setting or
  # a ruleset is blocking the policy, and silence would hide it.
  [ "$failed" -eq 0 ]
}

# open_dependabot_prs — repo<TAB>number<TAB>title<TAB>autoMergeRequestIsSet
open_dependabot_prs() {
  if [ -n "${AUTOMERGE_FETCH_CMD:-}" ]; then
    eval "$AUTOMERGE_FETCH_CMD"
    return
  fi
  gh api -X GET search/issues \
    -f q="org:${ORG} is:pr is:open author:app/dependabot" -f per_page=100 --paginate \
    --jq '.items[] | [(.repository_url | split("/") | last), (.number | tostring)] | @tsv' \
  | while IFS=$'\t' read -r repo number; do
      gh pr view "$number" -R "${ORG}/${repo}" \
        --json number,title,autoMergeRequest \
        --jq "[\"${repo}\", (.number|tostring), .title, (.autoMergeRequest != null | tostring)] | @tsv" 2>/dev/null
    done
}

selftest() {
  local pass=0 fail=0
  # Not a RETURN trap: `tmp` is local, so the trap would fire after it is out
  # of scope and die on `set -u`. Cleaned up explicitly at both exits instead.
  local tmp
  tmp=$(mktemp -d)
  ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
  bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

  # --- the title parser
  while IFS='|' read -r title want; do
    got=$(dependency_of "$title")
    if [ "$got" = "$want" ]; then ok "parsed \"${want}\""; else bad "parsed \"${got}\", want \"${want}\" from: ${title}"; fi
  done <<'CASES'
chore(deps): bump stripe from 21.0.1 to 22.6.2|stripe
chore(deps): Bump google.golang.org/genai from 1.36.0 to 1.71.0|google.golang.org/genai
chore(deps-dev): bump knip from 5.88.1 to 6.38.0|knip
chore(deps): bump the patch-and-minor group with 5 updates|the patch-and-minor group with 5 updates
chore(deps): bump tar and npm in /tools/npm|tar and npm
CASES

  # --- policy
  POLICY="$tmp/p.json"
  printf '%s' '{"enabled":true,"exclude_repos":[],"exclude_dependencies":[]}' >"$POLICY"
  if eligible gibson "chore(deps): bump stripe from 21.0.1 to 22.6.2"; then ok "an empty policy arms everything"; else bad "an empty policy excluded something"; fi

  printf '%s' '{"enabled":true,"exclude_repos":["Gibson"],"exclude_dependencies":[]}' >"$POLICY"
  if eligible gibson "chore(deps): bump stripe from 21.0.1 to 22.6.2"; then bad "an excluded repo was still armed"; else ok "an excluded repo is skipped, case-insensitively"; fi
  if eligible setec "chore(deps): bump stripe from 21.0.1 to 22.6.2"; then ok "a repo not on the exclude list is still armed"; else bad "a clean repo was skipped"; fi

  printf '%s' '{"enabled":true,"exclude_repos":[],"exclude_dependencies":["STRIPE"]}' >"$POLICY"
  if eligible gibson "chore(deps): bump stripe from 21.0.1 to 22.6.2"; then bad "an excluded dependency was still armed"; else ok "an excluded dependency is skipped, case-insensitively"; fi
  if eligible gibson "chore(deps): bump yaml from 2.8.3 to 2.9.1"; then ok "a dependency not on the exclude list is still armed"; else bad "a clean dependency was skipped"; fi
  # Whole-string, so excluding "stripe" must not catch "stripe-mock".
  if eligible gibson "chore(deps): bump stripe-mock from 1.0.0 to 1.1.0"; then ok "an exclude entry matches the whole name, not a prefix"; else bad "\"stripe\" wrongly excluded \"stripe-mock\""; fi

  # --- the kill switch, and the already-armed path
  printf '%s' '{"enabled":false,"exclude_repos":[],"exclude_dependencies":[]}' >"$POLICY"
  out=$(AUTOMERGE_FETCH_CMD="printf 'gibson\t1\tchore(deps): bump x from 1 to 2\tfalse\n'" DRY_RUN=1 sweep 2>&1)
  case "$out" in *"disabled"*) ok "enabled:false arms nothing" ;; *) bad "enabled:false still swept" ;; esac

  printf '%s' '{"enabled":true,"exclude_repos":[],"exclude_dependencies":[]}' >"$POLICY"
  DRY_RUN=1
  out=$(AUTOMERGE_FETCH_CMD="printf 'gibson\t1\tchore(deps): bump x from 1 to 2\ttrue\n'" sweep 2>&1)
  case "$out" in *"1 already armed"*) ok "an already-armed PR is left alone" ;; *) bad "re-armed a PR: $out" ;; esac

  # A QUEUED pull request reports autoMergeRequest: null, so it reaches the
  # loop looking unarmed. Counting it as newly armed would mean every sweep
  # reports the same queued PR as a fresh action, for as long as it sits in
  # the queue — which on a merge-queue repo is every PR, for days. arm() has
  # to settle it from what gh actually said.
  out=$(AUTOMERGE_ARM_CMD="echo already" \
        AUTOMERGE_FETCH_CMD="printf 'gibson\t1\tchore(deps): bump x from 1 to 2\tfalse\n'" sweep 2>&1)
  case "$out" in
    *"1 already armed"*) ok "a QUEUED PR reporting autoMergeRequest:null counts as already armed" ;;
    *) bad "a queued PR was counted as newly armed: $out" ;;
  esac
  case "$out" in
    *"armed    gibson#1"*) bad "a queued PR printed an 'armed' line" ;;
    *) ok "a queued PR prints no 'armed' line" ;;
  esac

  # A refusal must stay loud and must turn the run red.
  out=$(AUTOMERGE_ARM_CMD="echo failed" \
        AUTOMERGE_FETCH_CMD="printf 'gibson\t1\tchore(deps): bump x from 1 to 2\tfalse\n'" sweep 2>&1)
  rc=$?
  case "$out" in
    *"could not arm"*)
      if [ "$rc" -ne 0 ]; then ok "a refusal warns and fails the run"; else bad "a refusal warned but the run stayed green"; fi ;;
    *) bad "a refusal was swallowed: $out" ;;
  esac

  out=$(AUTOMERGE_FETCH_CMD="printf 'gibson\t1\tchore(deps): bump x from 1 to 2\tfalse\ngibson\t2\tchore(deps): bump y from 1 to 2\tfalse\n'" sweep 2>&1)
  case "$out" in *"2 would be armed"*) ok "two unarmed PRs are both armed" ;; *) bad "wrong arm count: $out" ;; esac

  # The dry-run summary must not claim it distinguished a queued PR, because
  # it cannot: it never makes the call that would tell it.
  case "$out" in
    *"upper bound"*) ok "the dry-run summary says its count is an upper bound" ;;
    *) bad "the dry run presented a count it cannot know as exact: $out" ;;
  esac

  out=$(AUTOMERGE_FETCH_CMD="printf ''" sweep 2>&1)
  case "$out" in *"0 open Dependabot PR(s)"*) ok "an empty backlog is a clean no-op" ;; *) bad "empty backlog misreported: $out" ;; esac
  DRY_RUN=0

  rm -rf "$tmp"
  echo
  echo "  $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
}

main() {
  case "${1:-}" in
    --selftest) selftest ;;
    --dry-run)  DRY_RUN=1; sweep ;;
    "")         sweep ;;
    *) echo "usage: $0 [--dry-run | --selftest]" >&2; exit 2 ;;
  esac
}

main "$@"
