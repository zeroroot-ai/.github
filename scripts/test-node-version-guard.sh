#!/usr/bin/env bash
# Mutation tests for scripts/check-node-version.sh. Each fixture under
# tests/fixtures/node-version/<case>/ is a project dir. The guard must go RED
# on every mismatch shape and GREEN on every agreeing shape, naming the
# offending line by content.
set -uo pipefail
cd "$(dirname "$0")/.."
G=scripts/check-node-version.sh
F=tests/fixtures/node-version
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
expect() { # <case> <want-rc> <must-contain> <label> [extra args]
  local c="$1" rc_want="$2" needle="$3" label="$4"; shift 4
  local out rc
  out=$(bash "$G" --dir "$F/$c" "$@" 2>&1); rc=$?
  if [ "$rc" = "$rc_want" ] && printf '%s' "$out" | grep -qF -- "$needle"; then ok "$label"; else bad "$label (rc=$rc)"; printf '%s\n' "$out" | sed 's/^/     /'; fi
}
expect agree 0 "2 node FROM line(s) match Node 24" "agreeing pair passes (tagged digest pins count)"
expect disagree 1 "FROM node:26.8.1-trixie-slim@sha256:c0753125 AS build" "major mismatch fails and names the FROM line"
expect disagree 1 "node:22-<variant>" "the message names the fix"
expect two-files 1 "2 Node version files" "two version files fail"
expect no-node-image 0 "0 node FROM line(s)" "Dockerfile without a node image is ignored"
expect tagless-digest 1 "tag-less digest pin" "tag-less digest pin fails"
expect hardcoded-workflow 1 "node-version: 22" "hand-written node-version in a workflow fails"
expect nvmrc-only 0 "match Node 24 from .nvmrc" ".nvmrc with a v prefix and an \${ARG} tag passes"
expect no-version-file 1 "no Node version file" "missing version file fails"
expect floating-tag 1 "names no major" "floating lts tag fails"
expect agree 1 "CI reads the Node version from .nvmrc" "CI pointed at a different file than the repo's fails" --version-file .nvmrc
expect agree 0 "match Node 24" "CI pointed at the repo's file passes" --version-file .tool-versions
echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
