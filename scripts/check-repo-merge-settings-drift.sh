#!/usr/bin/env bash
# Compares every non-archived repo's squash-merge settings against
# repo-settings/merge.json. Fails on any drift, on an empty fleet, and on a
# repo whose settings could not be read. Mutation-tested by
# scripts/test-repo-merge-settings-drift.sh, which drives it through
# MERGE_FETCH_CMD instead of the live API.
#
# Why this exists: with COMMIT_OR_PR_TITLE a one-commit PR lands its own
# commit subject on main, unlinted, and release-please and Dependabot both
# read that subject (hosted#264). The committed JSON is the source of truth;
# a hand change in a repo's settings page is drift.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORG="${ORG:-zeroroot-ai}"
SPEC="${MERGE_SETTINGS_SPEC:-${HERE}/../repo-settings/merge.json}"

want_title=$(jq -r '.squash_merge_commit_title // empty' "$SPEC")
want_message=$(jq -r '.squash_merge_commit_message // empty' "$SPEC")
if [ -z "$want_title" ] || [ -z "$want_message" ]; then
  echo "::error::${SPEC}: squash_merge_commit_title and squash_merge_commit_message are both required" >&2
  exit 1
fi

# Emits one line per repo: name<TAB>squash_merge_commit_title<TAB>squash_merge_commit_message
fetch() {
  if [ -n "${MERGE_FETCH_CMD:-}" ]; then
    eval "$MERGE_FETCH_CMD"
    return
  fi
  # The org list endpoint omits the squash fields; only the single-repo GET
  # returns them. Same shape as check-security-features-drift.sh.
  gh api "/orgs/${ORG}/repos?per_page=100&type=all" --paginate \
    --jq '.[] | select(.archived | not) | .name' \
  | while read -r name; do
      gh api "repos/${ORG}/${name}" \
        --jq '[.name, (.squash_merge_commit_title // "absent"), (.squash_merge_commit_message // "absent")] | @tsv' 2>/dev/null \
        || printf '%s\tunreadable\tunreadable\n' "$name"
    done
}

drift=0
checked=0
while IFS=$'\t' read -r name title message; do
  [ -z "${name:-}" ] && continue
  checked=$((checked + 1))
  if [ "$title" != "$want_title" ]; then
    echo "DRIFT ${name}: squash_merge_commit_title is '${title}', want '${want_title}'" >&2
    drift=$((drift + 1))
  fi
  if [ "$message" != "$want_message" ]; then
    echo "DRIFT ${name}: squash_merge_commit_message is '${message}', want '${want_message}'" >&2
    drift=$((drift + 1))
  fi
done < <(fetch)

if [ "$checked" -eq 0 ]; then
  echo "::error::no repos checked — an empty fleet is not a pass" >&2
  exit 1
fi
if [ "$drift" -gt 0 ]; then
  echo "::error::${drift} squash-merge setting(s) drifted across ${checked} repo(s); run apply-rulesets or fix repo-settings/merge.json" >&2
  exit 1
fi
echo "ok: ${checked} repo(s) squash with title=${want_title} message=${want_message}"
