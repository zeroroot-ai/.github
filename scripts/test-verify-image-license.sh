#!/usr/bin/env bash
#
# test-verify-image-license.sh — the guard must fail on an image with no
# license, and pass on one that has it. A guard that cannot fail is worse than
# no guard.
#
# Builds two tiny local images. Needs docker; skips cleanly without it so a
# workstation without a daemon does not report a false failure.
set -euo pipefail
cd "$(dirname "$0")/.."

S=actions/verify-image-license/verify-image-license.sh
PASS=0 FAIL=0

if ! docker info >/dev/null 2>&1; then
  echo "SKIP: no docker daemon. This suite runs in CI, where one exists."
  exit 0
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"; docker rmi -f licfixture-good licfixture-bad licfixture-empty >/dev/null 2>&1 || true' EXIT
printf 'Elastic License 2.0\n' > "$tmp/LICENSE"
: > "$tmp/EMPTY"

# scratch on purpose: a distroless or scratch image has no shell, which is why
# the guard uses `docker create` and `docker cp` rather than `docker run cat`.
cat > "$tmp/Dockerfile.good" <<'D'
FROM scratch
COPY LICENSE /licenses/LICENSE
D
cat > "$tmp/Dockerfile.bad" <<'D'
FROM scratch
COPY LICENSE /opt/app/LICENSE
D
cat > "$tmp/Dockerfile.empty" <<'D'
FROM scratch
COPY EMPTY /licenses/LICENSE
D

docker build -q -f "$tmp/Dockerfile.good"  -t licfixture-good  "$tmp" >/dev/null
docker build -q -f "$tmp/Dockerfile.bad"   -t licfixture-bad   "$tmp" >/dev/null
docker build -q -f "$tmp/Dockerfile.empty" -t licfixture-empty "$tmp" >/dev/null

if bash "$S" licfixture-good >/dev/null 2>&1; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: guard rejected an image that carries the license"; fi

# THE FIXTURE THIS EXISTS FOR.
if bash "$S" licfixture-bad >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "  FAIL: guard accepted an image with no license at /licenses/LICENSE"
else PASS=$((PASS+1)); fi

# An empty file satisfies "the path exists" and satisfies nothing else.
if bash "$S" licfixture-empty >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "  FAIL: guard accepted an EMPTY license file"
else PASS=$((PASS+1)); fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
