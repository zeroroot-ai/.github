#!/usr/bin/env bash
# Self-test for the gitleaks gate shipped in reusable-go-ci.yml and
# reusable-node-ci.yml. See gitleaks-gate-selftest.yml for why this exists.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

pin() { # file key -> value, read from the BEGIN/END-GITLEAKS-PIN block
  sed -n '/BEGIN-GITLEAKS-PIN/,/END-GITLEAKS-PIN/p' "$1" | sed -nE "s/^\s*$2:\s*([A-Za-z0-9.]+)\s*$/\1/p" | head -1
}
GO_V=$(pin .github/workflows/reusable-go-ci.yml GITLEAKS_VERSION)
GO_S=$(pin .github/workflows/reusable-go-ci.yml GITLEAKS_SHA256)
NODE_V=$(pin .github/workflows/reusable-node-ci.yml GITLEAKS_VERSION)
NODE_S=$(pin .github/workflows/reusable-node-ci.yml GITLEAKS_SHA256)
[ -n "$GO_V" ] && [ -n "$GO_S" ] || { echo "FAIL: reusable-go-ci.yml has no gitleaks pin block"; exit 1; }
[ "$GO_V" = "$NODE_V" ] && [ "$GO_S" = "$NODE_S" ] || { echo "FAIL: reusable-go-ci.yml and reusable-node-ci.yml pin different gitleaks builds ($GO_V/$GO_S vs $NODE_V/$NODE_S)"; exit 1; }
echo "pin agrees: gitleaks $GO_V sha256 $GO_S"

tmp=$(mktemp -d); trap "rm -rf '$tmp'" EXIT
curl -sSfL -o "$tmp/gitleaks.tgz" "https://github.com/gitleaks/gitleaks/releases/download/v${GO_V}/gitleaks_${GO_V}_linux_x64.tar.gz"
echo "${GO_S}  $tmp/gitleaks.tgz" | sha256sum -c - >/dev/null || { echo "FAIL: checksum mismatch for the pinned gitleaks tarball"; exit 1; }
tar -xzf "$tmp/gitleaks.tgz" -C "$tmp" gitleaks

# case 1: a generated credential-shaped token must be caught. Assembled at run
# time from random bytes so nothing credential-shaped is committed here, and so
# it is not one of the documented example values gitleaks itself allowlists.
rand() { head -c 64 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c "$1"; }
FAKE="sk_live_$(rand 24)"
mkdir -p "$tmp/dirty"
printf 'STRIPE_SECRET_KEY = "%s"\n' "$FAKE" > "$tmp/dirty/config"
rc=0; "$tmp/gitleaks" dir "$tmp/dirty" --no-banner --redact --exit-code 1 >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || { echo "FAIL case 1: the gate did not reject a credential-shaped token (rc=$rc)"; exit 1; }
echo "PASS case 1: credential-shaped token rejected"

# case 2: a same-line gitleaks:allow must be honoured (that is how fixtures are kept)
mkdir -p "$tmp/allowed"
printf 'STRIPE_SECRET_KEY = "%s" # gitleaks:allow\n' "$FAKE" > "$tmp/allowed/config"
"$tmp/gitleaks" dir "$tmp/allowed" --no-banner --redact --exit-code 1 >/dev/null 2>&1 || { echo "FAIL case 2: same-line gitleaks:allow was not honoured"; exit 1; }
echo "PASS case 2: same-line allow honoured"

# case 3: a clean tree passes
mkdir -p "$tmp/clean"; printf 'package main\n' > "$tmp/clean/main.go"
"$tmp/gitleaks" dir "$tmp/clean" --no-banner --redact --exit-code 1 >/dev/null 2>&1 || { echo "FAIL case 3: clean tree rejected"; exit 1; }
echo "PASS case 3: clean tree accepted"
