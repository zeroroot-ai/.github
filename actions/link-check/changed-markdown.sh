#!/usr/bin/env bash
# changed-markdown.sh - list the Markdown files a change touched.
#
# WHY
#
# The link checker fetches every external URL in every Markdown file it reads.
# On a pull request that touches no Markdown, that is a fetch of the whole
# tree for nothing, and an outage at any linked site fails the pull request
# (charts#251 stalled on a pin PR because one external host answered 500).
# A required check that fails a change for a fault outside the change is a
# guard defect. This script scopes a pull request run to the Markdown files
# the change added, copied, modified or renamed. The full sweep stays on the
# push to main and on the schedule, where an outage costs nobody a merge.
#
# CONTRACT
#
#   REPO_ROOT=<checkout> BASE_SHA=<sha> PATHS="." bash changed-markdown.sh
#
# Prints one path per line, relative to REPO_ROOT, for every *.md or *.mdx
# file that differs between BASE_SHA and HEAD with status A, C, M or R. A
# deleted file has nothing left to check and is not listed. PATHS narrows the
# list the way the action's `paths` input narrows a full run: a file is kept
# when it is one of the listed files or lives under one of the listed
# directories. "." keeps everything. BASE_SHA is fetched at depth 1 when the
# checkout does not carry it, which is the shape actions/checkout leaves.
#
#   bash changed-markdown.sh --selftest
#
# Builds a throwaway repository and proves the five cases the contract names.
# The action runs it before every scan, so the scoping cannot go inert.

set -euo pipefail

GUARD_NAME="changed-markdown"

fail() { echo "::error::${GUARD_NAME}: $*" >&2; exit 2; }

# ensure_commit <root> <sha>: make the base commit available for diffing.
ensure_commit() {
  local root="$1" sha="$2"
  if git -C "$root" cat-file -e "${sha}^{commit}" 2>/dev/null; then
    return 0
  fi
  git -C "$root" fetch --quiet --no-tags --depth=1 origin "$sha" \
    || fail "cannot fetch the base commit ${sha}"
}

# in_scope <file> <paths...>: 0 when the file is one of the paths or under one.
in_scope() {
  local file="$1"; shift
  local p
  for p in "$@"; do
    p="${p%/}"
    case "$p" in
      "."|"") return 0 ;;
    esac
    if [ "$file" = "$p" ] || [ "${file#"$p"/}" != "$file" ]; then
      return 0
    fi
  done
  return 1
}

# list_changed <root> <base> <paths...>: the contract, on stdout.
list_changed() {
  local root="$1" base="$2"; shift 2
  ensure_commit "$root" "$base"
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if in_scope "$f" "$@"; then
      printf '%s\n' "$f"
    fi
  done < <(git -C "$root" diff --name-only --diff-filter=ACMR "$base" HEAD -- '*.md' '*.mdx')
}

selftest() {
  local tmp
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  local repo="$tmp/repo"
  git init --quiet -b main "$repo"
  git -C "$repo" config user.email selftest@example.invalid
  git -C "$repo" config user.name selftest
  mkdir -p "$repo/docs" "$repo/gitops"
  printf '# a\n' >"$repo/README.md"
  printf '# gone\n' >"$repo/docs/gone.md"
  printf '# same\n' >"$repo/docs/same.md"
  printf 'v: 1\n' >"$repo/gitops/values.yaml"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m base
  local base
  base="$(git -C "$repo" rev-parse HEAD)"

  printf '# a\nchanged\n' >"$repo/README.md"          # modified: listed
  printf '# new\n' >"$repo/docs/new.mdx"               # added: listed
  git -C "$repo" mv docs/same.md docs/moved.md         # renamed: listed under the new name
  git -C "$repo" rm --quiet docs/gone.md               # deleted: not listed
  printf 'v: 2\n' >"$repo/gitops/values.yaml"          # not Markdown: not listed
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m change

  local got want
  got="$(list_changed "$repo" "$base" . | LC_ALL=C sort)"
  want="$(printf 'README.md\ndocs/moved.md\ndocs/new.mdx\n')"
  [ "$got" = "$want" ] || fail "selftest: whole tree: got [$got] want [$want]"

  got="$(list_changed "$repo" "$base" docs | LC_ALL=C sort)"
  want="$(printf 'docs/moved.md\ndocs/new.mdx\n')"
  [ "$got" = "$want" ] || fail "selftest: directory scope: got [$got] want [$want]"

  got="$(list_changed "$repo" "$base" README.md docs/new.mdx | LC_ALL=C sort)"
  want="$(printf 'README.md\ndocs/new.mdx\n')"
  [ "$got" = "$want" ] || fail "selftest: file scope: got [$got] want [$want]"

  got="$(list_changed "$repo" "$base" gitops)"
  [ -z "$got" ] || fail "selftest: a scope with no Markdown change must print nothing, got [$got]"

  # A pull request that touches no Markdown at all is the case that started
  # this: the list must be empty, so the caller can skip every fetch.
  printf 'v: 3\n' >"$repo/gitops/values.yaml"
  git -C "$repo" add -A
  git -C "$repo" commit --quiet -m pin
  local pinbase
  pinbase="$(git -C "$repo" rev-parse HEAD~1)"
  got="$(list_changed "$repo" "$pinbase" .)"
  [ -z "$got" ] || fail "selftest: a non-Markdown change must print nothing, got [$got]"

  echo "PASS: ${GUARD_NAME} selftest (5 cases)"
}

main() {
  case "${1:-}" in
    --selftest) selftest; exit 0 ;;
    "") ;;
    *) fail "unknown argument: $1" ;;
  esac
  local root="${REPO_ROOT:-${GITHUB_WORKSPACE:-.}}"
  local base="${BASE_SHA:-}"
  local paths="${PATHS:-.}"
  [ -d "$root/.git" ] || [ -f "$root/.git" ] || fail "REPO_ROOT is not a git checkout: ${root}"
  [ -n "$base" ] || fail "BASE_SHA is unset"
  # shellcheck disable=SC2086
  list_changed "$root" "$base" $paths
}

main "$@"
