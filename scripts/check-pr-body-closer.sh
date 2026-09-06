#!/usr/bin/env bash
# check-pr-body-closer.sh — fail a PR body that closes an issue with the one
# form GitHub ignores (.github#306, deploy ADR-0012 § Sign-off merge).
#
# GitHub honours `Closes #N` (same repo) and `Closes owner/repo#N` or the full
# issue URL (cross-repo). It silently ignores the bare `Closes repo#N`, so the
# PR merges and the issue stays open. Six fixed-but-open issues in July and
# every slice merged on 2026-08-25 came from exactly this.
#
#   check-pr-body-closer.sh <body-file>   exit 1 on a bare repo#N closer
#   check-pr-body-closer.sh --selftest    prove both directions
set -euo pipefail
KEYWORDS='[Cc]lose[sd]?|[Ff]ix(e[sd])?|[Rr]esolve[sd]?'
# a closer keyword, whitespace, then a repo name WITHOUT a slash, then #digits
BARE="(${KEYWORDS})[[:space:]]+[A-Za-z0-9_.-]+#[0-9]+"
check() {
  local f="$1" hits
  hits="$(grep -oE "$BARE" "$f" | grep -vE "(${KEYWORDS})[[:space:]]+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#" || true)"
  if [ -n "$hits" ]; then
    echo "❌ the PR body closes an issue with a form GitHub ignores:"
    echo "$hits" | sed 's/^/     /'
    echo "   use \`Closes #N\` for this repo, or \`Closes owner/repo#N\` / the full issue URL across repos."
    return 1
  fi
  echo "✅ no bare repo#N closer in the PR body"
}
if [ "${1:-}" = "--selftest" ]; then
  t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
  printf 'Closes deploy#12\n' > "$t/bad1"; printf 'Fixes gitops#3 and more\n' > "$t/bad2"
  printf 'Closes #12\n' > "$t/ok1"; printf 'Closes zeroroot-ai/deploy#12\n' > "$t/ok2"; printf 'Closes https://github.com/zeroroot-ai/deploy/issues/12\n' > "$t/ok3"; printf 'Refs deploy#12 (not a closer)\n' > "$t/ok4"
  for f in bad1 bad2; do check "$t/$f" >/dev/null && { echo "GUARD BROKEN: $f accepted" >&2; exit 2; }; done
  for f in ok1 ok2 ok3 ok4; do check "$t/$f" >/dev/null || { echo "GUARD BROKEN: $f rejected" >&2; exit 2; }; done
  echo "✅ self-test: bare repo#N closers rejected; #N, owner/repo#N, URLs and plain refs accepted"
  exit 0
fi
check "${1:?usage: check-pr-body-closer.sh <body-file> | --selftest}"
