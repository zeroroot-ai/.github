#!/usr/bin/env bash
# check-go-toolchain.sh — the builder image must carry the Go that go.mod names.
#
# Epic zeroroot-ai/.github#20, slice #22. Every Go repo said `go 1.26.8` in
# go.mod while its builder images said 1.26.4, 1.26.6 or a floating 1.25
# (gibson used four different golang tags). The builds only worked because
# Go downloads the toolchain go.mod names inside the build, so the pinned
# base was decoration and the mirror list carried tags nobody used.
#
# Two rules, keyed by content, never by line number:
#   1. Every `FROM ...golang:<tag>` in every Dockerfile carries the exact
#      version go.mod names (`toolchain goX.Y.Z` when present, else the `go`
#      directive). A floating `1.25` or a bare `1.26` is a mismatch unless it
#      equals that string. `${ARG}` tags resolve from an `ARG NAME=default`
#      in the same Dockerfile; anything else cannot be checked and fails.
#   2. A Dockerfile that builds on a golang image declares
#      `ARG GOTOOLCHAIN=local` so a mismatch fails the build instead of
#      downloading a toolchain (the reusable image build passes the same
#      value as a build-arg when the caller sets go_toolchain_local).
#
#   check-go-toolchain.sh [--go-mod go.mod] [--root .]   exit 1 on any hit
set -euo pipefail

GO_MOD="go.mod"; ROOT="."
while [ $# -gt 0 ]; do
  case "$1" in
    --go-mod) GO_MOD="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    *) echo "usage: $0 [--go-mod PATH] [--root DIR]" >&2; exit 2 ;;
  esac
done
cd "$ROOT"
[ -f "$GO_MOD" ] || { echo "❌ $GO_MOD not found under $(pwd)"; exit 1; }

want=$(awk '/^toolchain go[0-9]/{sub(/^toolchain go/,""); print; exit}' "$GO_MOD")
[ -n "$want" ] || want=$(awk '/^go [0-9]/{print $2; exit}' "$GO_MOD")
[ -n "$want" ] || { echo "❌ $GO_MOD has no go directive"; exit 1; }

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t files < <(git ls-files -co --exclude-standard -- '*Dockerfile*' | sort)
else
  mapfile -t files < <(find . -name '*Dockerfile*' -type f | sed 's|^\./||' | sort)
fi

hits=0; checked=0
for f in "${files[@]}"; do
  uses_golang=0
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qiE '^FROM[[:space:]]' || continue
    printf '%s' "$line" | grep -qiE '(^|[/[:space:]])golang:' || continue
    uses_golang=1; checked=$((checked+1))
    tag=$(printf '%s' "$line" | sed -E 's/.*golang:([^@[:space:]]+).*/\1/')
    if printf '%s' "$tag" | grep -q '\${\?[A-Za-z_]'; then
      var=$(printf '%s' "$tag" | sed -E 's/.*\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?.*/\1/')
      def=$(awk -v v="$var" '$1=="ARG" && index($2, v"=")==1 {sub(v"=","",$2); print $2; exit}' "$f")
      if [ -z "$def" ]; then
        echo "❌ $f: $line"
        echo "   the tag uses \$${var} and no \`ARG ${var}=<default>\` in this Dockerfile resolves it; pin the version in the ARG default"
        hits=$((hits+1)); continue
      fi
      tag=$(printf '%s' "$tag" | sed -E "s/\\\$\\{?${var}\\}?/${def}/")
    fi
    have=$(printf '%s' "$tag" | sed -E 's/^([0-9]+(\.[0-9]+)*).*/\1/')
    if [ "$have" != "$want" ]; then
      echo "❌ $f: $line"
      echo "   golang:${tag} is go ${have}, go.mod ($GO_MOD) names ${want}; move the FROM to golang:${want}${tag#$have} (or move go.mod) so both name the same toolchain"
      hits=$((hits+1))
    fi
  done < "$f"
  if [ "$uses_golang" = 1 ] && ! grep -qE '^ARG[[:space:]]+GOTOOLCHAIN=local([[:space:]]|$)' "$f"; then
    echo "❌ $f: no \`ARG GOTOOLCHAIN=local\`"
    echo "   add \`ARG GOTOOLCHAIN=local\` before the first golang build stage (and \`ENV GOTOOLCHAIN=\${GOTOOLCHAIN}\` in it) so a toolchain mismatch fails the build instead of downloading a toolchain"
    hits=$((hits+1))
  fi
done

if [ "$hits" -gt 0 ]; then
  echo "❌ go toolchain guard: ${hits} problem(s); go.mod names go ${want}"
  exit 1
fi
echo "✅ go toolchain guard: ${checked} golang FROM line(s) match go ${want}"
