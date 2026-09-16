#!/usr/bin/env bash
#
# verify-image-license.sh <image-ref> — fail unless the image carries its
# license text at /licenses/LICENSE.
#
# WHY. Apache-2.0 section 4(a) requires giving every recipient of a distribution
# a copy of the License. MIT requires the copyright and permission notice "in
# all copies or substantial portions of the Software". A container image we
# publish is a distribution. Measured 2026-09-16: 24 first-party Dockerfiles,
# zero copies. `zitadel-login` is the sharpest case — its image redistributes
# ZITADEL's MIT code.
#
# `docker create` is used rather than `docker run`, because a distroless or
# scratch image has no shell to run `cat` in. Creating a container never starts
# it, so the check works on an image with no shell and no entrypoint.
set -euo pipefail

ref="${1:?usage: $0 <image-ref>}"
want="${2:-/licenses/LICENSE}"

docker image inspect "$ref" >/dev/null 2>&1 || docker pull -q "$ref" >/dev/null

# The dummy command matters. `docker create` on an image with no CMD and no
# ENTRYPOINT fails with "no command specified" — a scratch or distroless base
# with neither is exactly the case this guard has to survive. The container is
# never started, so the command is never resolved and need not exist.
cid=$(docker create "$ref" /nonexistent-license-probe)
cleanup() { docker rm -f "$cid" >/dev/null 2>&1 || true; }
trap cleanup EXIT

out=$(mktemp)
if ! docker cp "$cid:${want}" "$out" >/dev/null 2>&1; then
  echo "::error::${ref} does not carry ${want}. Apache-2.0 4(a) and MIT both"
  echo "::error::require the notice to travel with a distribution, and an image"
  echo "::error::is one. Add 'COPY LICENSE /licenses/LICENSE' to the FINAL stage"
  echo "::error::of the Dockerfile. A copy in a builder stage ships nothing."
  exit 1
fi

if [ ! -s "$out" ]; then
  echo "::error::${ref} carries ${want} but it is empty."
  exit 1
fi

echo "PASS: ${ref} carries ${want} ($(wc -c < "$out") bytes)"
