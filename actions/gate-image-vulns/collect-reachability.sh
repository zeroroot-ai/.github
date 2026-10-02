#!/usr/bin/env bash
#
# collect-reachability.sh <image-ref> <reachdir> <binary-path>...
#
# Produces the reachability evidence gate-image-vulns.sh reads for a VENDORED
# binary: one that ships inside our image and that we do not compile.
#
# WHY. A Go stdlib finding from an image scanner is a version comparison — the
# binary's Go is behind a patch. For a binary we build that is the right
# question, because bumping Go is ours to do. For a vendored binary it is the
# wrong question and has no remedy: gVisor publishes every artifact built with
# the Go its own go.mod names, so eleven fixable HIGH stdlib findings arrived
# with nothing setec could do about any of them.
#
# govulncheck -mode=binary answers the right question. It reports a vulnerability
# only when the affected SYMBOL is present in the binary. Not an allowlist: no
# per-CVE entries, nothing to expire.
#
# Output per binary, keyed by a slug of its path:
#   <slug>.path       the path this slug stands for
#   <slug>.reachable  OSV ids and their CVE aliases that govulncheck reported
#   <slug>.failed     present when the analysis did not run — which BLOCKS
#
# An analysis that did not run is never a pass. Every failure path here writes
# .failed rather than an empty .reachable, because "found nothing" and "never
# looked" are indistinguishable to anything reading only the result.
set -euo pipefail

image="${1:?usage: $0 <image-ref> <reachdir> <binary-path>...}"
reachdir="${2:?missing reachdir}"
shift 2
[ "$#" -gt 0 ] || { echo "collect-reachability: no binary paths given"; exit 0; }

mkdir -p "$reachdir"
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# govulncheck is installed at a pinned version; a floating one would change the
# gate's verdict with no commit. Resolved explicitly from where go install wrote
# it, never with `command -v`: PATH routinely serves an older copy from another
# toolchain's packages dir, and then the pin decides nothing.
GOVULNCHECK_VERSION="${GOVULNCHECK_VERSION:-v1.1.4}"
echo "collect-reachability: installing golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}"
GOFLAGS='' go install "golang.org/x/vuln/cmd/govulncheck@${GOVULNCHECK_VERSION}"
gvc="$(go env GOPATH)/bin/govulncheck"
[ -x "$gvc" ] || { echo "collect-reachability: ${gvc} missing after install" >&2; exit 1; }

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

# One container, many copies out. docker cp needs a container, not an image.
cid="$(docker create "$image" 2>/dev/null)" || {
  echo "collect-reachability: could not create a container from ${image}" >&2
  exit 1
}
# shellcheck disable=SC2064  # expand cid now, so cleanup runs with the real id
trap "docker rm -f '$cid' >/dev/null 2>&1 || true; rm -rf '$workdir'" EXIT

for path in "$@"; do
  sl="$(slug "$path")"
  printf '%s\n' "$path" > "${reachdir}/${sl}.path"
  rm -f "${reachdir}/${sl}.reachable" "${reachdir}/${sl}.failed"

  local_bin="${workdir}/${sl}"
  if ! docker cp "${cid}:/${path#/}" "$local_bin" >/dev/null 2>&1; then
    printf 'docker cp failed: %s is not in the image\n' "$path" > "${reachdir}/${sl}.failed"
    echo "collect-reachability: ${path} is not in ${image}" >&2
    continue
  fi

  # -mode=binary needs no source and no network for the SCAN, but it does need
  # the vulnerability database, which is fetched. A fetch failure must land in
  # .failed rather than looking like a clean binary.
  err="${workdir}/${sl}.err"
  if ! out="$("$gvc" -mode=binary -json "$local_bin" 2>"$err")"; then
    {
      printf 'govulncheck exited non-zero for %s\n' "$path"
      tail -20 "$err" 2>/dev/null || true
    } > "${reachdir}/${sl}.failed"
    echo "collect-reachability: govulncheck failed on ${path}" >&2
    continue
  fi

  # The extraction lives in reachable-ids.jq so it can be tested without docker
  # or a vulnerability database — scripts/test-reachable-ids.sh does exactly that.
  # It was inline here first, and being inline is why it shipped untested: the
  # collector around it needs the network, and the jq in the middle of it does not.
  #
  # What it got wrong: govulncheck streams an `osv` DEFINITION for every advisory
  # it loads, and a `finding` only for what it actually found. Reading `.osv`
  # returned the whole database — 350 ids per gVisor binary, 665 for kata's shim —
  # so every finding looked reachable and nothing could ever be ruled out.
  if ! printf '%s' "$out" | jq -r -n -f "$(dirname "$0")/reachable-ids.jq" 2>/dev/null \
       | LC_ALL=C sort -u > "${reachdir}/${sl}.reachable"; then
    printf 'could not parse govulncheck JSON for %s\n' "$path" > "${reachdir}/${sl}.failed"
    echo "collect-reachability: unparseable govulncheck output for ${path}" >&2
    continue
  fi

  n=$(wc -l < "${reachdir}/${sl}.reachable" | tr -d ' ')
  # A FLOOR ON PLAUSIBILITY. The first version of this returned the entire
  # vulnerability database and reported "350 reachable advisory id(s)" with a
  # straight face. A real binary reaches a handful. A set this large means the
  # extraction is reading definitions again, and treating it as evidence would
  # make every finding block for a reason unrelated to the binary.
  if [ "$n" -gt 60 ]; then
    {
      printf 'implausible reachability result for %s: %s advisory ids\n' "$path" "$n"
      printf 'That is the size of the advisory database, not of one binary.\n'
      printf 'The extraction is almost certainly reading osv definitions instead of findings.\n'
    } > "${reachdir}/${sl}.failed"
    rm -f "${reachdir}/${sl}.reachable"
    echo "collect-reachability: ${path}: ${n} ids is implausible; refusing to use it as evidence" >&2
    continue
  fi
  echo "collect-reachability: ${path}: ${n} reachable advisory id(s)"
done
