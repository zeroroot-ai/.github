#!/usr/bin/env bash
# Mutation tests for scripts/check-go-toolchain.sh. Each fixture under
# tests/fixtures/go-toolchain/<case>/ is a go.mod + Dockerfile pair. The guard
# must go RED on every mismatch shape and GREEN on every agreeing shape, and
# the red output must name the offending FROM line by content.
set -uo pipefail
cd "$(dirname "$0")/.."
G=scripts/check-go-toolchain.sh
F=tests/fixtures/go-toolchain
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
expect() { # <case> <want-rc> <must-contain> <label>
  local out rc
  out=$(bash "$G" --root "$F/$1" 2>&1); rc=$?
  if [ "$rc" = "$2" ] && printf '%s' "$out" | grep -qF -- "$3"; then ok "$4"; else bad "$4 (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     /'; fi
}
expect agree 0 "1 golang FROM line(s) match go 1.26.8" "agreeing pair passes"
expect disagree 1 "FROM ghcr.io/zeroroot-ai/mirror/golang:1.26.4-alpine AS builder" "patch mismatch fails and names the FROM line"
expect disagree 1 "golang:1.26.8-alpine" "the message names the fix"
expect floating 1 "FROM golang:1.26-alpine AS builder" "floating minor tag fails"
expect no-golang 0 "0 golang FROM line(s)" "Dockerfile without a golang image is ignored"
expect arg-resolved 0 "1 golang FROM line(s) match" "\${ARG} tag resolves from the ARG default"

# Rule 3 — .tool-versions, the third declaration site (.github#152). The
# mismatch case is the one that matters: asdf resolves `go` from this file, and
# when it names a version asdf lacks the shim prints its installed list and
# exits WITHOUT running go, which reads as success to anything piping the tail.
expect tv-agree 0 ".tool-versions golang 1.26.8 agrees" "agreeing .tool-versions is reported, not just silent"
expect tv-mismatch 1 ".tool-versions: golang 1.26.4, go.mod" "a .tool-versions four patches behind go.mod fails"
expect tv-mismatch 1 "exits WITHOUT running" "the message explains why a silent shim is the real risk"
expect agree 0 "no .tool-versions (optional)" "a repo with no .tool-versions is not a finding"
expect arg-unresolved 1 "no \`ARG GO_VERSION=<default>\`" "unresolvable \${ARG} tag fails"
expect no-toolchain-local 1 "no \`ARG GOTOOLCHAIN=local\`" "golang stage without GOTOOLCHAIN=local fails"
expect toolchain-line 0 "match go 1.26.8" "toolchain directive wins over the go directive"
# mutation: the guard itself must not pass an empty go.mod
tmp=$(mktemp -d); : > "$tmp/go.mod"; printf 'FROM golang:1.26.8\n' > "$tmp/Dockerfile"
if bash "$G" --root "$tmp" >/dev/null 2>&1; then bad "empty go.mod passes"; else ok "empty go.mod fails"; fi
rm -rf "$tmp"
echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
