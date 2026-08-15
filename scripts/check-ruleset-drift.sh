#!/usr/bin/env bash
# Ruleset drift guard — live GitHub ruleset state vs the committed
# rulesets/{org,repo}/*.json that apply-rulesets.yml PUTs.
#
# Why this exists (.github#264)
# ----------------------------
# `apply-rulesets.yml` reconciles by a FULL PUT of the committed file. So an
# out-of-band live edit (`gh api --method PUT .../rulesets/<id>`, or a click in
# the GitHub UI) survives only until the next push that touches ANY
# rulesets/**.json file — for ANY repo in the org. At that moment the live edit
# is silently reverted.
#
# That is how gibson-executor's `Lint (golangci-lint)` required check came to
# exist only in live state: it was applied out of band, gibson-executor#369 was
# closed against it, and the next unrelated ruleset edit would have deleted it
# and restored the exact condition the issue was filed to fix.
#
# This is NOT the "guard that cannot fail" class. The guard works. Its
# ENFORCEMENT existed only as live state that the org's own reconciler is
# guaranteed to overwrite. Nothing in CI could see it, because the two facts
# that have to agree live on opposite sides of the API boundary.
#
# What it asserts
# ---------------
# For every rulesets/org/*.json and rulesets/repo/*.json: the live ruleset with
# that `name` exists, and everything the file DECLARES holds live.
#
# "Everything the file declares" rather than "live is byte-identical to the
# file", because the API echoes back a superset of what we PUT. It fills in
# defaults for parameters we never authored — a `pull_request` rule comes back
# carrying `dismissal_restriction` and `required_reviewers` that appear in no
# committed file. A byte-equality check reports drift on all five repos with a
# `pull_request` rule on day one, and a guard that is red on arrival gets
# switched off within a day. So the comparison is:
#
#   objects  every key the FILE declares must exist live and match recursively.
#            Keys only live are server defaults; the file asserts nothing about
#            them, so neither does this guard.
#   arrays   same length, and elements match pairwise after sorting. Length
#            equality is what keeps the object rule from becoming a loophole:
#            an extra required_status_checks entry live, or an extra rule live,
#            changes a length and is caught. (This is the .github#264
#            direction — live STRICTER than the file — and it must fail,
#            because it is pending deletion by the next apply.)
#   scalars  exact.
#
# Array ORDER is not semantic to GitHub and the API does not preserve ours, so
# arrays are sorted on both sides first — by a stable semantic key (`.type` for
# rules, `.context` for required checks) rather than by serialisation, since
# the two sides serialise differently and sorting by that would misalign them.
#
# A missing live ruleset is drift, not a pass. That is deliberate: `gitops`'s
# ruleset file has been committed with four required contexts while the repo
# has had NO live ruleset at all (the private-repo plan gate makes the POST in
# apply-rulesets.yml fail, and that failure is only a `::warning::`). A drift
# check that treated "absent" as "nothing to compare" would have reported green
# on a repo with zero branch protection.
#
# Testability
# -----------
# The live-state fetch is injectable so the behaviour contract can be
# mutation-tested with no network and no org-admin token — see
# scripts/test-ruleset-drift.sh, which is what the pull_request lane runs.
#
#   RULESET_FETCH_CMD  command invoked as: $RULESET_FETCH_CMD <scope> <slug> <name>
#                      where <scope> is "org" or "repo" and <slug> is the org
#                      name or the repo name. It must print the live ruleset
#                      JSON object on stdout, or print nothing / exit non-zero
#                      if no ruleset by that name exists.
#                      Default: fetch via `gh api`.
#
#   RULESET_DIR        root containing org/ and repo/ subdirs. Default: rulesets
#   RULESET_ORG        GitHub org. Default: zeroroot-ai
#
# Exit 0 = live matches every committed file. Exit 1 = at least one drifted.

set -uo pipefail

ORG="${RULESET_ORG:-zeroroot-ai}"
DIR="${RULESET_DIR:-rulesets}"

# Projection + canonical ordering. Applied identically to both sides.
NORMALISE='
  def sortlist: if type == "array" then sort_by(tojson) else . end;

  def normcond:
    reduce ("ref_name", "repository_name", "repository_property") as $k (.;
      if (.[$k]? | type) == "object"
      then .[$k].include = ((.[$k].include // []) | sortlist)
         | .[$k].exclude = ((.[$k].exclude // []) | sortlist)
      else . end);

  def normrule:
      (if .parameters.required_status_checks? != null
       then .parameters.required_status_checks |= sort_by(.context)
       else . end)
    | (if .parameters.allowed_merge_methods? != null
       then .parameters.allowed_merge_methods |= sortlist
       else . end);

  {
    name:          .name,
    target:        .target,
    enforcement:   .enforcement,
    bypass_actors: ((.bypass_actors // []) | sortlist),
    conditions:    ((.conditions // {}) | normcond),
    rules:         ((.rules // []) | map(normrule) | sort_by(.type))
  }
'

# Recursive "does live satisfy everything the file declares" predicate.
# $e = expected (committed file), $a = actual (live). See the header for why
# objects are subset-matched while arrays are length-exact.
MATCHES='
  def matches($e; $a):
    if ($e | type) != ($a | type) then false
    elif ($e | type) == "object" then
      all(($e | keys_unsorted)[]; . as $k
          | ($a | has($k)) and matches($e[$k]; $a[$k]))
    elif ($e | type) == "array" then
      (($e | length) == ($a | length))
      and all(range(0; $e | length); . as $i | matches($e[$i]; $a[$i]))
    else $e == $a
    end;
  matches(.expected; .actual)
'

# Default live fetch: look the ruleset up by name, then read it in full.
# Listing and reading are separate calls because the list endpoint omits
# `rules`.
default_fetch() {
  local scope="$1" slug="$2" name="$3" base list id
  case "$scope" in
    org)  base="/orgs/${slug}/rulesets" ;;
    repo) base="/repos/${ORG}/${slug}/rulesets" ;;
    *)    echo "unknown scope: $scope" >&2; return 1 ;;
  esac

  list="$(gh api "$base" 2>/dev/null)" || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$list" || return 1

  id="$(jq -r --arg n "$name" '.[] | select(.name == $n) | .id' <<<"$list" | head -1)"
  [[ "$id" =~ ^[0-9]+$ ]] || return 1

  gh api "${base}/${id}" 2>/dev/null || return 1
}

fetch_live() {
  if [ -n "${RULESET_FETCH_CMD:-}" ]; then
    # shellcheck disable=SC2086
    $RULESET_FETCH_CMD "$1" "$2" "$3"
  else
    default_fetch "$1" "$2" "$3"
  fi
}

drifted=0
checked=0

check_one() {
  local scope="$1" file="$2" slug name live want got
  slug="$(basename "$file" .json)"
  [ "$scope" = "org" ] && slug="$ORG"

  name="$(jq -r '.name' "$file")"
  checked=$((checked + 1))

  live="$(fetch_live "$scope" "$slug" "$name")"
  if [ -z "$live" ] || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$live"; then
    echo "::error::DRIFT ${scope}/${slug}: no live ruleset named '${name}' — the committed file is not in force at all"
    drifted=$((drifted + 1))
    return
  fi

  want="$(jq -S "$NORMALISE" "$file")"
  got="$(jq -S "$NORMALISE" <<<"$live")"

  if jq -ne --argjson expected "$want" --argjson actual "$got" \
       '{expected: $expected, actual: $actual} | '"$MATCHES" >/dev/null 2>&1; then
    echo "ok    ${scope}/${slug} (${name})"
    return
  fi

  echo "::error::DRIFT ${scope}/${slug} (${name}): live state does not satisfy ${file}"
  echo "--- committed (${file})"
  echo "+++ live"
  # Diff is presentational only — it shows server-default keys the comparison
  # above deliberately ignores, so read it as a pointer, not as the verdict.
  diff -u <(echo "$want") <(echo "$got") | tail -n +3
  drifted=$((drifted + 1))
}

shopt -s nullglob
for f in "${DIR}"/org/*.json;  do check_one org  "$f"; done
for f in "${DIR}"/repo/*.json; do check_one repo "$f"; done

if [ "$checked" -eq 0 ]; then
  echo "::error::no ruleset files found under ${DIR}/{org,repo} — refusing to report green on an empty check"
  exit 1
fi

echo
if [ "$drifted" -gt 0 ]; then
  cat >&2 <<EOF
::error::${drifted}/${checked} ruleset(s) drifted from the committed source of truth.

Live GitHub state is NOT authoritative here — rulesets/{org,repo}/*.json is, and
apply-rulesets.yml overwrites live with the file on the next push touching any
of them. So a live-only change is not "already applied", it is pending deletion.

Fix by committing the intended state to the file, not by re-editing live:
  1. edit rulesets/<scope>/<name>.json to the state you want
  2. merge it — the push trigger PUTs every file
  3. re-run this check to confirm live now matches
EOF
  exit 1
fi

echo "All ${checked} ruleset(s) match the committed source of truth."
