#!/usr/bin/env bash
# check-org-refs.sh - references a public reader cannot follow.
#
# lychee checks links. It cannot see two classes of dead reference that the
# 2026-09-05 history reset and the private repositories left in public
# Markdown:
#
#   1. A link or a shorthand reference into a repository the reader cannot
#      open: a private one (`github.com/zeroroot-ai/hosted`, `hosted#108`) or a
#      deleted one (`deploy#1382`). lychee runs with GITHUB_TOKEN, which is
#      scoped to the calling repository, so it cannot tell "private" from
#      "gone", and the org policy excludes the private names so that a private
#      repository may link to another one. Both cases render as a 404 to a
#      stranger.
#   2. An issue or pull request number from before the reset. The reset
#      renumbered every repository from 1, so a number larger than the
#      repository's newest issue or pull request can only be a pre-reset
#      number. `gibson#1280` is one when gibson's newest issue is #126.
#
# Both classes only matter to a stranger, so the guard runs against PUBLIC
# calling repositories and skips private ones with a notice.
#
# SCOPE
#
# The Markdown files under PATHS, the same set lychee reads. Three always-exempt
# paths: the changelog, which release-please owns; docs/adr/, because an
# accepted ADR records what was true when it was written and is not edited; and
# any walked file that carries the fixture marker `<!-- link-check: fixture -->`,
# which is how the deliberately broken fixtures in this repository stay out of
# the repository-wide run while the fixture job still names them directly.
#
# WHAT COUNTS AS A REFERENCE
#
#   https://github.com/zeroroot-ai/<name>[/...]      a link into an org repo
#   zeroroot-ai/<name>#<n>, <name>#<n>                a shorthand cross-repo ref
#   #<n>                                              a ref into the calling repo
#
# A bare `#<n>` with exactly six digits is skipped: that shape is a hex color
# in a style note, and no repository in this org has a six-digit issue.
#
# USAGE
#
#   REPO_ROOT=<path> PATHS="." CALLER_REPO=owner/name bash check-org-refs.sh
#   bash check-org-refs.sh --selftest         # prove the guard can fail
#   bash check-org-refs.sh --check-policy     # lychee.toml agrees with data/
#
# Environment:
#   CALLER_VISIBILITY   public | private | auto (default: ask the API)
#   NOT_DISTRIBUTED     path to data/not-distributed.txt (default: this repo's)
#   GH_TOKEN            what `gh api` authenticates with
#
# Exit codes: 0 clean, 1 violation or self-test failure, 2 usage or setup error.
set -euo pipefail

GUARD_NAME="org-refs"
ORG="${ORG:-zeroroot-ai}"
FIXTURE_MARKER="<!-- link-check: fixture -->"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOT_DISTRIBUTED="${NOT_DISTRIBUTED:-${HERE}/../../data/not-distributed.txt}"

# --- test seams -------------------------------------------------------------
# The self-test runs without a network. These two variables replace the API:
#   ORG_REFS_FAKE_STATUS  "name=public name=private name=missing ..."
#   ORG_REFS_FAKE_MAX     "name=<newest issue number> ..."
FAKE_STATUS="${ORG_REFS_FAKE_STATUS:-}"
FAKE_MAX="${ORG_REFS_FAKE_MAX:-}"

fail() { echo "::error::${GUARD_NAME}: $*" >&2; exit 2; }

lookup_fake() { # $1 table, $2 key -> value or ""
  local pair
  for pair in $1; do
    if [ "${pair%%=*}" = "$2" ]; then echo "${pair#*=}"; return; fi
  done
}

is_not_distributed() {
  [ -f "$NOT_DISTRIBUTED" ] || return 1
  grep -vE '^\s*(#|$)' "$NOT_DISTRIBUTED" | grep -qxF "$1"
}

# repo_status <name> -> public | private | missing
repo_status() {
  local name="$1" v
  if [ -n "$FAKE_STATUS" ]; then
    v="$(lookup_fake "$FAKE_STATUS" "$name")"
    echo "${v:-missing}"
    return
  fi
  if is_not_distributed "$name"; then echo private; return; fi
  if v="$(gh api "repos/${ORG}/${name}" --jq .visibility 2>/dev/null)"; then
    echo "$v"
  else
    echo missing
  fi
}

# newest_number <name> -> the highest issue or pull request number, or 0
newest_number() {
  local name="$1" n
  if [ -n "$FAKE_MAX" ]; then
    n="$(lookup_fake "$FAKE_MAX" "$name")"
    echo "${n:-0}"
    return
  fi
  n="$(gh api "repos/${ORG}/${name}/issues?state=all&sort=created&direction=desc&per_page=1" \
        --jq '.[0].number // 0' 2>/dev/null || echo 0)"
  echo "${n:-0}"
}

caller_visibility() {
  case "${CALLER_VISIBILITY:-auto}" in
    public|private) echo "${CALLER_VISIBILITY}" ;;
    auto)
      [ -n "${CALLER_REPO:-}" ] || fail "CALLER_REPO is unset and CALLER_VISIBILITY is auto"
      gh api "repos/${CALLER_REPO}" --jq .visibility 2>/dev/null \
        || fail "cannot read the visibility of ${CALLER_REPO}"
      ;;
    *) fail "CALLER_VISIBILITY must be public, private or auto" ;;
  esac
}

# collect_files <repo-root> <paths...> -> one repo-relative path per line
collect_files() {
  local root="$1"; shift
  local p f
  for p in "$@"; do
    case "$p" in
      *.md|*.mdx) echo "$p" ;;
      *)
        find "${root}/${p%/}" -type f \( -name '*.md' -o -name '*.mdx' \) \
          -not -path '*/node_modules/*' -not -path '*/.git/*' \
          -not -path '*/vendor/*' -not -path '*/dist/*' \
          -not -path '*/.next/*' -not -path '*/.worktrees/*' \
        | sed -E "s#^${root}/##; s#^\./##" | sort \
        | while IFS= read -r f; do
            case "$f" in
              CHANGELOG.md|*/CHANGELOG.md|docs/adr/*|*/docs/adr/*) continue ;;
            esac
            grep -qF "$FIXTURE_MARKER" "${root}/${f}" && continue
            echo "$f"
          done
        ;;
    esac
  done
}

# scan <repo-root> <caller-name> <files...> -> violations on stdout
scan() {
  local root="$1" caller="$2"; shift 2
  local f line
  declare -A status_of=() max_of=()
  local violations=0

  status_for() { # memoized repo_status
    if [ -z "${status_of[$1]+x}" ]; then status_of[$1]="$(repo_status "$1")"; fi
    echo "${status_of[$1]}"
  }
  max_for() {
    if [ -z "${max_of[$1]+x}" ]; then max_of[$1]="$(newest_number "$1")"; fi
    echo "${max_of[$1]}"
  }

  for f in "$@"; do
    [ -f "${root}/${f}" ] || fail "no such file: ${f}"
    # One line per hit: <line>:<kind>:<name>:<number>
    while IFS=: read -r line kind name num; do
      [ -n "$line" ] || continue
      local st
      if [ "$name" = "@self" ]; then name="$caller"; fi
      if [ "$kind" = "link" ]; then
        st="$(status_for "$name")"
        if [ "$st" != "public" ]; then
          echo "${f}:${line}: links into github.com/${ORG}/${name}, which is ${st} and a 404 to a public reader"
          violations=$((violations + 1))
        fi
        continue
      fi
      st="$(status_for "$name")"
      if [ "$st" != "public" ]; then
        echo "${f}:${line}: ${name}#${num} refers into a repository that is ${st} and a 404 to a public reader"
        violations=$((violations + 1))
        continue
      fi
      local max
      max="$(max_for "$name")"
      if [ "$num" -gt "$max" ]; then
        echo "${f}:${line}: ${name}#${num} is a pre-reset number (the newest issue or pull request in ${name} is #${max})"
        violations=$((violations + 1))
      fi
    done < <(extract_refs "${root}/${f}")
  done
  return $(( violations > 0 ))
}

# extract_refs <file> -> <line>:<kind>:<name>:<number>
extract_refs() {
  local file="$1"
  {
    grep -noP 'https?://github\.com/'"${ORG}"'/[A-Za-z0-9_.-]+' "$file" \
      | sed -E 's/\.git$//; s#^([0-9]+):.*/([A-Za-z0-9_.-]+)$#\1:link:\2:0#' || true
    grep -noP '(?<![\w/.-])(?:'"${ORG}"'/)?[A-Za-z0-9_.-]+#\d+(?![\w-])' "$file" \
      | sed -E 's#^([0-9]+):(.*/)?([A-Za-z0-9_.-]+)\#([0-9]+)$#\1:ref:\3:\4#' || true
    grep -noP '(?<![\w/.&#-])#\d+(?![\w-])' "$file" \
      | sed -E 's/^([0-9]+):#([0-9]+)$/\1:ref:@self:\2/' \
      | grep -vE ':[0-9]{6}$' || true
  } | grep -E '^[0-9]+:(link|ref):' || true
}

check_policy() {
  # lychee.toml carries the private names as one regex alternation, so lychee
  # does not fail a private repository for linking to another one. That list
  # and data/not-distributed.txt must agree, or one of them is stale.
  local toml="${HERE}/lychee.toml" want have
  want="$(grep -vE '^\s*(#|$)' "$NOT_DISTRIBUTED" | sort | paste -sd'|')"
  have="$(grep -oE 'github\\\\\.com/'"${ORG}"'/\(\?:[^)]+\)' "$toml" \
          | sed -E 's/.*\(\?://; s/\)$//' | tr '|' '\n' | sort | paste -sd'|')"
  if [ "$want" != "$have" ]; then
    echo "::error::${GUARD_NAME}: lychee.toml excludes (${have}) but data/not-distributed.txt names (${want})" >&2
    return 1
  fi
  echo "PASS: lychee.toml and data/not-distributed.txt name the same private repositories"
}

selftest() {
  local rc out
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/docs/adr" "$tmp/sub"
  export ORG_REFS_FAKE_STATUS="gibson=public sdk=public hosted=private deploy=missing self=public"
  export ORG_REFS_FAKE_MAX="gibson=126 sdk=44 self=10"
  export NOT_DISTRIBUTED="$tmp/none.txt"
  FAKE_STATUS="$ORG_REFS_FAKE_STATUS"; FAKE_MAX="$ORG_REFS_FAKE_MAX"

  cat >"$tmp/clean.md" <<'EOF'
# Clean
See [gibson](https://github.com/zeroroot-ai/gibson.git) and gibson#120, sdk#44, #10 and #3.
A style note uses the color #333333 and the anchor [here](#1-intro).
The heading "## 1. Intro" and `&#123;` are not references. RFC 7519 has no hash.
EOF
  cat >"$tmp/dirty.md" <<'EOF'
# Dirty
- [private](https://github.com/zeroroot-ai/hosted/blob/main/README.md)
- a shorthand into a private repo: hosted#108
- a deleted repo: deploy#1382
- a pre-reset number: gibson#1280
- a pre-reset own number: #991
- with the org prefix: zeroroot-ai/sdk#300
EOF
  printf '%s\n# Fixture\ngibson#9999\n' "$FIXTURE_MARKER" >"$tmp/sub/fixture.md"
  printf '# ADR\ngibson#9999\n' >"$tmp/docs/adr/0001-x.md"
  printf '# Changelog\ngibson#9999\n' >"$tmp/CHANGELOG.md"

  local failures=0
  # 1. The dirty file yields exactly six violations.
  set +e; out="$(scan "$tmp" self dirty.md)"; rc=$?; set -e
  if [ "$rc" -ne 1 ] || [ "$(printf '%s\n' "$out" | grep -c .)" -ne 6 ]; then
    echo "selftest FAILED: dirty.md should give 6 violations, got rc=${rc}:"; echo "$out"; failures=$((failures + 1))
  fi
  # 2. The clean file is clean.
  set +e; out="$(scan "$tmp" self clean.md)"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    echo "selftest FAILED: clean.md should be clean:"; echo "$out"; failures=$((failures + 1))
  fi
  # 3. A walk skips the fixture marker, docs/adr/ and the changelog, and still
  #    sees dirty.md.
  local walked
  walked="$(collect_files "$tmp" .)"
  if [ "$walked" != "$(printf 'clean.md\ndirty.md')" ]; then
    echo "selftest FAILED: the walk should list clean.md and dirty.md only, got:"; echo "$walked"; failures=$((failures + 1))
  fi
  # 4. A fixture named directly is checked even though the walk skips it.
  set +e; out="$(scan "$tmp" self sub/fixture.md)"; rc=$?; set -e
  if [ "$rc" -ne 1 ]; then
    echo "selftest FAILED: sub/fixture.md named directly should fail"; failures=$((failures + 1))
  fi
  if [ "$failures" -ne 0 ]; then
    echo "::error::${GUARD_NAME}: selftest FAILED (${failures})" >&2; exit 1
  fi
  echo "PASS: ${GUARD_NAME} selftest (4 cases)"
}

main() {
  case "${1:-}" in
    --selftest) selftest; exit 0 ;;
    --check-policy) check_policy; exit $? ;;
    "") ;;
    *) fail "unknown argument: $1" ;;
  esac
  local root="${REPO_ROOT:-${GITHUB_WORKSPACE:-.}}"
  local paths="${PATHS:-.}"
  local caller="${CALLER_REPO:-${GITHUB_REPOSITORY:-}}"
  [ -d "$root" ] || fail "REPO_ROOT is not a directory: ${root}"
  [ -n "$caller" ] || fail "CALLER_REPO is unset"

  local vis
  vis="$(caller_visibility)"
  if [ "$vis" != "public" ]; then
    echo "::notice::${GUARD_NAME}: ${caller} is ${vis}; only a public repository has readers who cannot open a private link"
    exit 0
  fi

  local files
  # shellcheck disable=SC2086
  mapfile -t files < <(collect_files "$root" $paths)
  [ "${#files[@]}" -gt 0 ] || fail "no Markdown under ${paths}"

  local out rc
  set +e; out="$(scan "$root" "${caller##*/}" "${files[@]}")"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    echo "::error::${GUARD_NAME}: references a public reader cannot follow:" >&2
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    echo "Rewrite the sentence without the reference. Pre-reset numbers cannot be recovered." >&2
    exit 1
  fi
  echo "PASS: ${GUARD_NAME}: ${#files[@]} Markdown files, no reference a public reader cannot follow"
}

main "$@"
