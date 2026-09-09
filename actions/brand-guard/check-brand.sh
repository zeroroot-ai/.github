#!/usr/bin/env bash
# check-brand.sh - the org-wide brand guard.
#
# The org is zeroroot-ai, the domain is zeroroot.ai, the CRD group is
# gibson.zeroroot.ai and the company name is Zero Root AI. Four strings from
# before the rename still leak into new files. Each one is a public artifact
# once it reaches main, so this guard rejects all four.
#
# The guard runs against the CALLING repository's tree. It lives in
# zeroroot-ai/.github so that one copy serves every repo, and it replaces the
# per-repo copies that used to live in gibson (scripts/check-brand.sh) and in
# dashboard (scripts/check-no-legacy-product-name.mjs).
#
# MATCHING
#
# All four patterns match case-insensitively. The retired domain and the
# retired slug appear in lower case, in title case in prose and in upper case
# in environment variable values, and one guard that catches every spelling is
# easier to reason about than four rules with four case policies. The cost is
# that the company-name pattern also matches the lower-case spelling of the
# same three words, which ordinary prose about a zero day does not produce:
# "zero-day vulnerability" carries a hyphen and no third word.
#
# SCOPE
#
# Every file `git ls-files` reports in REPO_ROOT. Binary files are skipped by
# grep -I. Untracked files are not scanned, because an untracked file cannot
# reach main.
#
# EXEMPTIONS, KEYED BY CONTENT, NEVER BY LINE NUMBER
#
#   1. The allow file `.brand-guard-allow` at the repository root. It lists
#      repo-relative paths, one per line. Every entry needs a `# why:` comment
#      on the line above it. An entry that no longer matches anything fails
#      the guard, so the list shrinks and cannot rot.
#   2. The marker `brand-guard-exempt:` on the same line as the string. A test
#      that asserts a retired string is absent has to contain that string, so
#      it declares itself where the string is.
#   3. Three always-exempt paths: the changelog, which release-please owns and
#      which records the rename commits; the code-scanning dismissal log,
#      which quotes alert text verbatim; and the allow file itself.
#
# Both exemption forms survive an unrelated edit anywhere in the file. Neither
# names a line number.
#
# USAGE
#
#   REPO_ROOT=<path> bash check-brand.sh   # scan a tree
#   bash check-brand.sh --selftest         # prove the guard can fail
#
# Exit codes: 0 clean, 1 violation or self-test failure, 2 usage or setup error.
set -euo pipefail

GUARD_NAME="brand-guard"
ALLOW_FILE=".brand-guard-allow"
EXEMPT_MARKER="brand-guard-exempt:"

REPO_ROOT="${REPO_ROOT:-${GITHUB_WORKSPACE:-.}}"

# The retired strings, as extended regular expressions. Read the header for why
# every one of them is matched case-insensitively.
PATTERNS=(
  'zero-day\.ai'
  'zero-day-ai'
  'Zero Day AI'
  'gibson\.io'
)

# One alternation for the sweep. Per-pattern greps run only on the lines the
# sweep returns, so a repository with thousands of files costs one grep pass.
COMBINED='zero-day\.ai|zero-day-ai|Zero Day AI|gibson\.io'

# Paths that are exempt in every repository. Keep this list at three entries:
# each one is a place the guard cannot protect.
ALWAYS_EXEMPT=(
  # release-please owns the changelog and records what commit subjects said at
  # the time, including the rename commits themselves.
  "CHANGELOG.md"
  # The code-scanning dismissal log quotes alert text verbatim.
  "docs/code-scanning-dismissals.md"
  # The allow file names the paths it allows.
  "$ALLOW_FILE"
  # This guard names the strings it forbids. The path only appears in the
  # scanned tree when zeroroot-ai/.github scans itself.
  "actions/brand-guard/check-brand.sh"
)

declare -A ALLOW_PATHS=()
declare -A ALLOW_USED=()
ALLOW_MALFORMED=0

is_always_exempt() {
  local rel=$1 entry
  for entry in "${ALWAYS_EXEMPT[@]}"; do
    [ "$rel" = "$entry" ] && return 0
  done
  return 1
}

# Read `.brand-guard-allow`. Format:
#
#   # why: one sentence saying why this path must carry a retired string
#   path/relative/to/the/repo/root
#
# Blank lines are ignored. A comment that is not a `# why:` comment does not
# arm an entry, so a stray note cannot silently authorise the path below it.
parse_allow_file() {
  local file="$REPO_ROOT/$ALLOW_FILE"
  local line path why="" lineno=0
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      "") continue ;;
      \#*)
        if [[ "$line" =~ ^#[[:space:]]*why: ]]; then
          why="$line"
        fi
        continue
        ;;
    esac
    path="${line#"${line%%[![:space:]]*}"}"
    path="${path%"${path##*[![:space:]]}"}"
    [ -z "$path" ] && continue
    if [ -z "$why" ]; then
      echo "${GUARD_NAME}: ${ALLOW_FILE}:${lineno}: '${path}' has no '# why:' comment above it" >&2
      ALLOW_MALFORMED=$((ALLOW_MALFORMED + 1))
    fi
    ALLOW_PATHS["$path"]=1
    why=""
  done <"$file"
}

# Every tracked file that carries a retired string, as "path<TAB>line<TAB>text".
collect_hits() {
  (
    cd "$REPO_ROOT" || exit 2
    git ls-files -z | while IFS= read -r -d '' rel; do
      is_always_exempt "$rel" && continue
      printf '%s\0' "$rel"
    done | xargs -0 -r grep -IHEnsi -- "$COMBINED" || true
  ) | awk -F: '
    NF >= 3 {
      rel = $1
      lineno = $2
      text = substr($0, length(rel) + length(lineno) + 3)
      printf "%s\t%s\t%s\n", rel, lineno, text
    }
  '
}

scan() {
  local rel lineno text pattern violations=0 suppressed=0

  ALLOW_PATHS=()
  ALLOW_USED=()
  ALLOW_MALFORMED=0

  if [ ! -d "$REPO_ROOT/.git" ] && ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    echo "${GUARD_NAME}: ${REPO_ROOT} is not a git repository" >&2
    return 2
  fi

  parse_allow_file

  while IFS=$'\t' read -r rel lineno text; do
    [ -z "$rel" ] && continue
    case "$text" in
      *"$EXEMPT_MARKER"*)
        suppressed=$((suppressed + 1))
        continue
        ;;
    esac
    if [ -n "${ALLOW_PATHS[$rel]:-}" ]; then
      ALLOW_USED["$rel"]=1
      suppressed=$((suppressed + 1))
      continue
    fi
    for pattern in "${PATTERNS[@]}"; do
      printf '%s' "$text" | grep -Eqi -- "$pattern" || continue
      echo "::error file=${rel},line=${lineno}::${GUARD_NAME}: retired brand string (${pattern})"
      echo "${rel}:${lineno}: ${pattern}"
      violations=$((violations + 1))
    done
  done < <(collect_hits)

  local path stale=0
  for path in "${!ALLOW_PATHS[@]}"; do
    [ -n "${ALLOW_USED[$path]:-}" ] && continue
    echo "${GUARD_NAME}: ${ALLOW_FILE}: '${path}' carries no retired brand string - remove the entry" >&2
    stale=$((stale + 1))
  done

  if [ "$violations" -gt 0 ]; then
    {
      echo "${GUARD_NAME}: ${violations} line(s) carry a retired brand string."
      echo "The domain is zeroroot.ai, the CRD group is gibson.zeroroot.ai and the"
      echo "company name is Zero Root AI. Rewrite the reference."
      echo "If the string is load-bearing, because a test asserts it is absent, put"
      echo "'${EXEMPT_MARKER} <reason>' on the same line, or add the path to"
      echo "${ALLOW_FILE} under a '# why:' comment."
    } >&2
  fi

  if [ "$violations" -gt 0 ] || [ "$stale" -gt 0 ] || [ "$ALLOW_MALFORMED" -gt 0 ]; then
    return 1
  fi

  echo "${GUARD_NAME}: no retired brand strings (${suppressed} exempt line(s))."
  return 0
}

# ---------------------------------------------------------------------------
# Self-test. Each case builds a throwaway git repository, because the scan
# reads its file list from `git ls-files` and a fixture that skips that path
# proves nothing about the guard that runs in CI.
# ---------------------------------------------------------------------------
SELFTEST_FAILURES=0

new_repo() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
}

put_file() {
  local dir=$1 rel=$2 content=$3
  mkdir -p "$dir/$(dirname "$rel")"
  printf '%s\n' "$content" >"$dir/$rel"
  git -C "$dir" add -- "$rel"
}

# assert_scan <expected-rc> <dir> <description> [expected-output-substring]
assert_scan() {
  local want=$1 dir=$2 what=$3 needle=${4:-}
  local out rc=0
  out=$(REPO_ROOT="$dir" scan 2>&1) || rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "SELFTEST FAILED: ${what} (want rc=${want}, got rc=${rc})" >&2
    printf '%s\n' "$out" >&2
    SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
    return 0
  fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then
    echo "SELFTEST FAILED: ${what} (output does not name '${needle}')" >&2
    printf '%s\n' "$out" >&2
    SELFTEST_FAILURES=$((SELFTEST_FAILURES + 1))
    return 0
  fi
  echo "SELFTEST PASSED: ${what}"
}

selftest() {
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  # One failing fixture per pattern, each in its own repository, so a guard
  # that lost a pattern fails here instead of passing by finding nothing.
  local fixtures=(
    'apiVersion: gibson.zero-day.ai/v1'
    'image: ghcr.io/zeroroot-ai/zero-day-ai-daemon:v1'
    '// Copyright 2026 Zero Day AI'
    'label: gibson.io/sandbox-host=true'
  )
  local i=0 pattern
  for pattern in "${PATTERNS[@]}"; do
    new_repo "$tmp/pattern$i"
    put_file "$tmp/pattern$i" "nested/fixture.yaml" "${fixtures[$i]}"
    assert_scan 1 "$tmp/pattern$i" "pattern ${pattern} rejects its fixture" "$pattern"
    i=$((i + 1))
  done

  # Case-insensitive matching, which the header explains.
  new_repo "$tmp/upper"
  put_file "$tmp/upper" "docs/notes.md" 'See https://ZERO-DAY.AI/pricing for the old page.'
  assert_scan 1 "$tmp/upper" "an upper-case spelling is rejected"

  # A clean tree passes.
  new_repo "$tmp/clean"
  put_file "$tmp/clean" "ok.yaml" 'apiVersion: gibson.zeroroot.ai/v1alpha1'
  put_file "$tmp/clean" "LICENSE" '// Copyright 2026 Zero Root AI'
  assert_scan 0 "$tmp/clean" "a clean tree is accepted"

  # The allow file exempts a listed path.
  new_repo "$tmp/allow"
  put_file "$tmp/allow" "legacy/notes.md" 'The old site was at zero-day.ai until 2026-08.'
  put_file "$tmp/allow" "$ALLOW_FILE" '# why: this note records the retirement of the old site
legacy/notes.md'
  assert_scan 0 "$tmp/allow" "the allow file exempts a listed path"

  # An allow-file entry with no reason above it fails.
  new_repo "$tmp/nowhy"
  put_file "$tmp/nowhy" "legacy/notes.md" 'The old site was at zero-day.ai until 2026-08.'
  put_file "$tmp/nowhy" "$ALLOW_FILE" 'legacy/notes.md'
  assert_scan 1 "$tmp/nowhy" "an allow-file entry with no '# why:' comment fails" "has no '# why:' comment"

  # An allow-file entry that no longer matches anything fails, so the list
  # shrinks as the tree gets clean.
  new_repo "$tmp/stale"
  put_file "$tmp/stale" "ok.yaml" 'apiVersion: gibson.zeroroot.ai/v1alpha1'
  put_file "$tmp/stale" "$ALLOW_FILE" '# why: nothing here carries a retired string any more
ok.yaml'
  assert_scan 1 "$tmp/stale" "a stale allow-file entry fails" "remove the entry"

  # The inline marker exempts the line that carries it.
  new_repo "$tmp/marker"
  put_file "$tmp/marker" "assert_absent_test.go" 'const retired = "gibson.zero-day.ai" // brand-guard-exempt: this test asserts the retired group is gone'
  assert_scan 0 "$tmp/marker" "the inline marker exempts its line"

  # The marker exempts one line only, never the whole file.
  new_repo "$tmp/markerline"
  put_file "$tmp/markerline" "assert_absent_test.go" 'const retired = "gibson.zero-day.ai" // brand-guard-exempt: this test asserts the retired group is gone
const leaked = "gibson.zero-day.ai"'
  assert_scan 1 "$tmp/markerline" "the marker exempts one line, not the file"

  if [ "$SELFTEST_FAILURES" -gt 0 ]; then
    echo "${GUARD_NAME}: ${SELFTEST_FAILURES} self-test assertion(s) failed." >&2
    return 1
  fi
  echo "${GUARD_NAME}: every self-test assertion passed."
  return 0
}

case "${1:-}" in
  --selftest) selftest ;;
  "") scan ;;
  *)
    echo "usage: $0 [--selftest]" >&2
    exit 2
    ;;
esac
