#!/usr/bin/env bash
# check-node-version.sh — one Node version per repo, and every copy agrees.
#
# Epic zeroroot-ai/.github#20, slice #23. docs-site ran CI on Node 22 and
# shipped an image on Node 26; zerocool-plugins declared 22.21.1 and shipped
# 26.8.1. The version lived in a version file, in `node-version:` inputs and in
# Dockerfile FROM lines, and nothing compared them.
#
# Three rules, keyed by content, never by line number:
#   1. Exactly one version file in the project dir: `.tool-versions` (with a
#      `nodejs <ver>` line) or `.nvmrc` / `.node-version`. None is a failure
#      (declare one). Two is a failure (one source).
#   2. Every `FROM ...node:<tag>` / `...node@sha256:` in every Dockerfile
#      carries the same MAJOR as the version file. A tag-less digest pin
#      cannot be checked and fails: pin as `node:<major>-<variant>@sha256:...`.
#      `${ARG}` tags resolve from an `ARG NAME=default` in the same file.
#   3. No workflow under .github/workflows sets `node-version:` by hand;
#      setup-node reads `node-version-file` so CI and the image agree.
#
#   check-node-version.sh [--dir .] [--version-file <name>]   exit 1 on any hit
set -euo pipefail

DIR="."; VFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --version-file) VFILE="$2"; shift 2 ;;
    *) echo "usage: $0 [--dir DIR] [--version-file NAME]" >&2; exit 2 ;;
  esac
done
cd "$DIR"

hits=0
found=()
[ -f .tool-versions ] && grep -qE '^nodejs[[:space:]]' .tool-versions && found+=(.tool-versions)
[ -f .nvmrc ] && found+=(.nvmrc)
[ -f .node-version ] && found+=(.node-version)
if [ "${#found[@]}" -eq 0 ]; then
  echo "❌ no Node version file in $(pwd): add .tool-versions with a \`nodejs <version>\` line (or .nvmrc) and let setup-node read it with node-version-file"
  exit 1
fi
if [ "${#found[@]}" -gt 1 ]; then
  echo "❌ ${#found[@]} Node version files: ${found[*]}; keep exactly one so the version has one source"
  exit 1
fi
src="${found[0]}"
if [ -n "$VFILE" ] && [ "$VFILE" != "$src" ] && [ "$VFILE" != "./$src" ]; then
  echo "❌ CI reads the Node version from $VFILE but the repo's version file is $src; point node-version-file at $src"
  exit 1
fi
case "$src" in
  .tool-versions) want=$(awk '$1=="nodejs"{print $2; exit}' .tool-versions) ;;
  *) want=$(tr -d 'v \n\r' < "$src") ;;
esac
major="${want%%.*}"
[[ "$major" =~ ^[0-9]+$ ]] || { echo "❌ $src names Node \"$want\", which has no numeric major"; exit 1; }

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t files < <(git ls-files -co --exclude-standard -- '*Dockerfile*' | sort)
else
  mapfile -t files < <(find . -name '*Dockerfile*' -type f | sed 's|^\./||' | sort)
fi
checked=0
for f in "${files[@]}"; do
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qiE '^FROM[[:space:]]' || continue
    printf '%s' "$line" | grep -qiE '(^|[/[:space:]])node[:@]' || continue
    checked=$((checked+1))
    ref=$(printf '%s' "$line" | sed -E 's/^FROM[[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?//I; s/[[:space:]]+AS[[:space:]].*$//I; s/[[:space:]]+as[[:space:]].*$//')
    if printf '%s' "$ref" | grep -qE 'node@sha256:'; then
      echo "❌ $f: $line"
      echo "   a tag-less digest pin cannot be checked against $src (Node $want); pin as node:${major}-<variant>@sha256:<digest>"
      hits=$((hits+1)); continue
    fi
    tag=$(printf '%s' "$ref" | sed -E 's/.*node:([^@[:space:]]+).*/\1/')
    if printf '%s' "$tag" | grep -q '\${\?[A-Za-z_]'; then
      var=$(printf '%s' "$tag" | sed -E 's/.*\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?.*/\1/')
      def=$(awk -v v="$var" '$1=="ARG" && index($2, v"=")==1 {sub(v"=","",$2); print $2; exit}' "$f")
      if [ -z "$def" ]; then
        echo "❌ $f: $line"
        echo "   the tag uses \$${var} and no \`ARG ${var}=<default>\` in this Dockerfile resolves it"
        hits=$((hits+1)); continue
      fi
      tag=$(printf '%s' "$tag" | sed -E "s/\\\$\\{?${var}\\}?/${def}/")
    fi
    have="${tag%%[^0-9]*}"
    if [ -z "$have" ]; then
      echo "❌ $f: $line"
      echo "   node:${tag} names no major (a floating \`lts\`/\`latest\`/\`current\` tag); pin node:${major}-<variant>"
      hits=$((hits+1)); continue
    fi
    if [ "$have" != "$major" ]; then
      echo "❌ $f: $line"
      echo "   node:${tag} is Node ${have}, $src says ${want}; move the FROM to node:${major}-<variant> (or move $src) so CI and the image run the same major"
      hits=$((hits+1))
    fi
  done < "$f"
done

if [ -d .github/workflows ]; then
  while IFS= read -r hit; do
    echo "❌ $hit"
    echo "   setup-node must read node-version-file: $src, never a hand-written node-version"
    hits=$((hits+1))
  done < <(grep -nHE '^[[:space:]]+node-version:[[:space:]]' .github/workflows/*.yml .github/workflows/*.yaml 2>/dev/null || true)
fi

if [ "$hits" -gt 0 ]; then
  echo "❌ node version guard: ${hits} problem(s); $src names Node ${want}"
  exit 1
fi
echo "✅ node version guard: ${checked} node FROM line(s) match Node ${major} from $src"
