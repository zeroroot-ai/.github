#!/usr/bin/env bash
# check-spelling.sh - the org writes American English (AGENTS.md § 12).
#
# The rule lived in AGENTS.md and nothing enforced it, so the org SECURITY.md
# and half the READMEs drifted into British spelling. This guard runs where the
# other public-reader checks run, on every Markdown file lychee reads, and it
# replaces the per-repo copy that docs-site carried.
#
# THE LIST IS SHORT ON PURPOSE
#
# It carries the spellings that appeared in the estate, not a dictionary. A
# guard that fires on a word a writer believes is correct gets disabled, and
# then it protects nothing. Words with a proper-noun collision (centre, as in
# a named security centre; programme) are left out.
#
# WHAT IS SCANNED
#
# Prose only. Fenced code blocks, inline code spans and URLs are stripped
# before matching, because an identifier or a path is not prose and may not
# be respelled. ALL-CAPS tokens never match: `CANCELLED` is an enum value.
#
# EXEMPTIONS, KEYED BY CONTENT, NEVER BY LINE NUMBER
#
#   1. The marker `spelling-guard-exempt:` on the same line as the word, for a
#      quotation that must stay verbatim.
#   2. Always-exempt paths: the changelog, which release-please owns;
#      docs/code-scanning-dismissals.md, which quotes alert text verbatim; and
#      docs/adr/, because an accepted ADR is a record and is not edited.
#   3. A walked file carrying `<!-- link-check: fixture -->`, so the fixture
#      stays out of the repository-wide run while the fixture job names it.
#
# USAGE
#
#   REPO_ROOT=<path> PATHS="." bash check-spelling.sh
#   bash check-spelling.sh --selftest
#
# Exit codes: 0 clean, 1 violation or self-test failure, 2 usage or setup error.
set -euo pipefail

GUARD_NAME="spelling-guard"
EXEMPT_MARKER="spelling-guard-exempt:"
FIXTURE_MARKER="<!-- link-check: fixture -->"

# British stem -> American stem. A stem matches the whole word plus the
# endings the word takes (e, es, ed, er, ers, ing, ation, ations, s, d, r, rs,
# ion, ions, ment, ments), so one entry covers "organise", "organised" and
# "organisation".
SPELLINGS=(
  "analyse=analyze"
  "analysing=analyzing"
  "artefact=artifact"
  "authoris=authoriz"
  "behaviour=behavior"
  "cancelled=canceled"
  "catalogue=catalog"
  "centred=centered"
  "colour=color"
  "customis=customiz"
  "defence=defense"
  "favour=favor"
  "fulfil=fulfill"
  "grey=gray"
  "honour=honor"
  "initialis=initializ"
  "labelled=labeled"
  "licence=license"
  "minimis=minimiz"
  "modelled=modeled"
  "normalis=normaliz"
  "optimis=optimiz"
  "organis=organiz"
  "prioritis=prioritiz"
  "realis=realiz"
  "recognis=recogniz"
  "sanitis=sanitiz"
  "serialis=serializ"
  "standardis=standardiz"
  "summaris=summariz"
  "synchronis=synchroniz"
  "utilis=utiliz"
  "visualis=visualiz"
  "whilst=while"
  "amongst=among"
)

fail() { echo "::error::${GUARD_NAME}: $*" >&2; exit 2; }

# One alternation of every stem. Each stem carries its own [Xx] first letter so
# the sentence-initial capital is caught without a case-insensitive flag, which
# would also match ALL-CAPS identifiers.
pattern() {
  local alts=() entry stem first rest
  for entry in "${SPELLINGS[@]}"; do
    stem="${entry%%=*}"
    first="${stem:0:1}"; rest="${stem:1}"
    alts+=("[${first^^}${first}]${rest}")
  done
  local IFS='|'
  echo '\b('"${alts[*]}"')(e|es|ed|er|ers|ing|ation|ations|s|d|r|rs|ion|ions|ment|ments)?(?![a-z])'
}

american_for() { # $1 the matched word -> the American spelling
  local word="$1" entry stem to lower
  lower="$(echo "$word" | tr 'A-Z' 'a-z')"
  for entry in "${SPELLINGS[@]}"; do
    stem="${entry%%=*}"; to="${entry#*=}"
    if echo "$lower" | grep -qP "^${stem}"; then
      echo "$lower" | sed -E "s/^${stem}/${to}/"
      return
    fi
  done
  echo "?"
}

# prose <file> -> the file with code fences, code spans and URLs blanked, line
# numbers preserved, so a hit reports the real line.
prose() {
  awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; print ""; next }
    fence { print ""; next }
    { print }
  ' "$1" | sed -E 's/`[^`]*`//g; s#https?://[^ )>]+##g'
}

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
              CHANGELOG.md|*/CHANGELOG.md|docs/code-scanning-dismissals.md|docs/adr/*|*/docs/adr/*) continue ;;
            esac
            grep -qF "$FIXTURE_MARKER" "${root}/${f}" && continue
            echo "$f"
          done
        ;;
    esac
  done
}

# scan <root> <files...> -> violations on stdout, exit 1 if any
scan() {
  local root="$1"; shift
  local f re hit line word violations=0
  re="$(pattern)"
  for f in "$@"; do
    [ -f "${root}/${f}" ] || fail "no such file: ${f}"
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      line="${hit%%:*}"; word="${hit#*:}"
      sed -n "${line}p" "${root}/${f}" | grep -qF "$EXEMPT_MARKER" && continue
      echo "${f}:${line}: ${word} (American spelling: $(american_for "$word"))"
      violations=$((violations + 1))
    done < <(prose "${root}/${f}" | grep -noP "$re" || true)
  done
  return $(( violations > 0 ))
}

selftest() {
  local rc out failures=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cat >"$tmp/dirty.md" <<'EOF'
# Dirty
The organisation authorised a colour change.
It recognises the behaviour and normalises the licence text.
Whilst cancelled, the artefacts were labelled grey.
Please organise and summarise the catalogue.
EOF
  cat >"$tmp/clean.md" <<'EOF'
# Clean
The organization authorized a color change. An unlicensed build has no license.
The status `CANCELLED` and the value `cancelled` are code, not prose.
See https://example.com/colour-scheme for the theme. A MISSION_CANCELLED event.
```
cancelled = true  # a fenced block is code
```
He quoted "the behaviour" verbatim. spelling-guard-exempt: a quotation
We deliver value. The council was dissolved. A licensed professional.
EOF
  set +e; out="$(scan "$tmp" dirty.md)"; rc=$?; set -e
  if [ "$rc" -ne 1 ] || [ "$(printf '%s\n' "$out" | grep -c .)" -ne 15 ]; then
    echo "selftest FAILED: dirty.md should give 15 violations, got rc=${rc}:"; echo "$out"; failures=$((failures + 1))
  fi
  set +e; out="$(scan "$tmp" clean.md)"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    echo "selftest FAILED: clean.md should be clean:"; echo "$out"; failures=$((failures + 1))
  fi
  mkdir -p "$tmp/docs/adr"; printf '# ADR\nthe old behaviour\n' >"$tmp/docs/adr/0001-x.md"
  printf '# Log\nthe old behaviour\n' >"$tmp/CHANGELOG.md"
  if [ "$(collect_files "$tmp" .)" != "$(printf 'clean.md\ndirty.md')" ]; then
    echo "selftest FAILED: the walk should skip docs/adr/ and the changelog"; failures=$((failures + 1))
  fi
  if [ "$(american_for "Organisation")" != "organization" ] || [ "$(american_for "analysed")" != "analyzed" ]; then
    echo "selftest FAILED: american_for mapping"; failures=$((failures + 1))
  fi
  if [ "$failures" -ne 0 ]; then
    echo "::error::${GUARD_NAME}: selftest FAILED (${failures})" >&2; exit 1
  fi
  echo "PASS: ${GUARD_NAME} selftest (4 cases, ${#SPELLINGS[@]} stems)"
}

main() {
  case "${1:-}" in
    --selftest) selftest; exit 0 ;;
    "") ;;
    *) fail "unknown argument: $1" ;;
  esac
  local root="${REPO_ROOT:-${GITHUB_WORKSPACE:-.}}"
  local paths="${PATHS:-.}"
  [ -d "$root" ] || fail "REPO_ROOT is not a directory: ${root}"
  local files
  # shellcheck disable=SC2086
  mapfile -t files < <(collect_files "$root" $paths)
  [ "${#files[@]}" -gt 0 ] || fail "no Markdown under ${paths}"
  local out rc
  set +e; out="$(scan "$root" "${files[@]}")"; rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    echo "::error::${GUARD_NAME}: British spelling in prose (AGENTS.md § 12 requires American spelling):" >&2
    printf '%s\n' "$out" | sed 's/^/  /' >&2
    exit 1
  fi
  echo "PASS: ${GUARD_NAME}: ${#files[@]} Markdown files, American spelling throughout"
}

main "$@"
