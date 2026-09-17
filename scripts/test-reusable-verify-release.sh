#!/usr/bin/env bash
#
# test-reusable-verify-release.sh — the release policy must verify what the
# shared build produces, and must refuse the wrong repo or commit.
#
# The policy's first version matched the certificate SAN against the CALLER
# repo. A reusable workflow signs with its own identity, so that regexp could
# never match, no repo ever called the policy, and nothing noticed for months.
# These assertions run offline. They read the shipped workflow, and they
# extract the shell blocks between the BEGIN-*/END-* markers and drive them
# with crafted input. No network, no registry, no cosign.
set -euo pipefail
cd "$(dirname "$0")/.."

WF=.github/workflows/reusable-verify-release.yml
BUILD=.github/workflows/reusable-image-build.yml
FIXTURE=tests/fixtures/verify-release-caller-identity.yml
PASS=0 FAIL=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# ---------------------------------------------------------------------------
# policy_flaws <workflow>: one line per flaw, nothing for a sound policy.
# Keyed by content, never by line number.
# ---------------------------------------------------------------------------
policy_flaws() {
  local f="$1" n_verify n_repo n_sha spdx
  if grep -qE -- '--certificate-identity-regexp.*inputs\.expected_subject_repo' "$f"; then
    echo "identity regexp matches the caller repo, but the shared build signs with its own identity"
  fi
  if ! grep -qE -- '--certificate-identity-regexp.*reusable-image-build' "$f"; then
    echo "identity regexp does not name the shared build workflow"
  fi
  n_verify=$(grep -cE '^\s*cosign (verify|verify-attestation)( |$)' "$f" || true)
  n_repo=$(grep -cE -- '--certificate-github-workflow-repository' "$f" || true)
  n_sha=$(grep -cE -- '--certificate-github-workflow-sha' "$f" || true)
  [ "$n_verify" -gt 0 ] || echo "no cosign verify at all"
  [ "$n_repo" -eq "$n_verify" ] || echo "$n_verify cosign verifies but $n_repo bind the caller repo"
  [ "$n_sha" -eq "$n_verify" ]  || echo "$n_verify cosign verifies but $n_sha bind the commit"
  if grep -qE -- '--type slsaprovenance' "$f"; then
    echo "asks cosign for a slsaprovenance attestation; buildx provenance lives in the image index, not in a cosign attestation"
  fi
  grep -q 'BEGIN-PROVENANCE-CHECK' "$f" || echo "no provenance check against the image index"
  spdx=$(awk '/--type spdxjson/{f=1} f{print} f&&/"\$IMAGE"/{f=0}' "$f")
  [ -n "$spdx" ] || echo "no SBOM attestation check"
  if [ -n "$spdx" ]; then
    grep -q -- '--use-signed-timestamps' <<<"$spdx" || echo "SBOM check does not use the RFC 3161 timestamp"
    grep -q -- '--insecure-ignore-tlog'  <<<"$spdx" || echo "SBOM check demands a Rekor entry the build never writes (.github#223)"
  fi
  grep -qE '^\s+cosign-release: v[0-9]' "$f" || echo "cosign release not pinned"
}

echo "== the shipped policy is sound =="
flaws=$(policy_flaws "$WF")
if [ -z "$flaws" ]; then ok; else bad "shipped policy: $flaws"; fi

echo "== THE FIXTURE THIS EXISTS FOR: the pre-fix policy is rejected, for the right reasons =="
flaws=$(policy_flaws "$FIXTURE")
[ -n "$flaws" ] && ok || bad "the caller-identity fixture was accepted"
grep -q "matches the caller repo" <<<"$flaws" && ok || bad "fixture: caller-repo regexp not named"
grep -q "bind the caller repo"    <<<"$flaws" && ok || bad "fixture: missing repo bind not named"
grep -q "bind the commit"         <<<"$flaws" && ok || bad "fixture: missing commit bind not named"
grep -q "slsaprovenance"          <<<"$flaws" && ok || bad "fixture: slsaprovenance not named"
grep -q "Rekor"                   <<<"$flaws" && ok || bad "fixture: tlog demand not named"

echo "== verify and build pin the same cosign release =="
pv=$(grep -E '^\s+cosign-release: v' "$WF"    | head -1 | tr -d ' ')
pb=$(grep -E '^\s+cosign-release: v' "$BUILD" | head -1 | tr -d ' ')
[ -n "$pb" ] && ok || bad "build does not pin cosign (installer default v3.0.6 mislabels the SBOM attestation)"
[ "$pv" = "$pb" ] && ok || bad "verify pins '$pv' but build pins '$pb'"

# ---------------------------------------------------------------------------
# The shell blocks, extracted and driven.
# ---------------------------------------------------------------------------
block() { awk -v b="BEGIN-$1" -v e="END-$1" '$0 ~ b {f=1; next} $0 ~ e {f=0} f' "$WF"; }
eval "$(block RESOLVE-DIGEST)"
eval "$(block PROVENANCE-CHECK)"
eval "$(block SBOM-CHECK)"

echo "== resolve: a digest ref passes through, a tag resolves =="
got=$(resolve_digest_ref "ghcr.io/zeroroot-ai/x@sha256:abc")
[ "$got" = "ghcr.io/zeroroot-ai/x@sha256:abc" ] && ok || bad "digest ref changed to $got"
mkdir -p "$tmp/bin"; printf '#!/usr/bin/env bash\necho "{\\"digest\\":\\"sha256:def\\"}"\n' > "$tmp/bin/docker"; chmod +x "$tmp/bin/docker"
got=$(PATH="$tmp/bin:$PATH" resolve_digest_ref "ghcr.io/zeroroot-ai/x:v1.2.3")
[ "$got" = "ghcr.io/zeroroot-ai/x@sha256:def" ] && ok || bad "tag resolved to $got"

echo "== provenance: binds source and revision, refuses anything else =="
SHA=54e5ff57fc519058165e5502bdf3a1802f945617
prov() { # name source revision [platform]
  jq -n --arg s "$2" --arg r "$3" --arg p "${4:-linux/amd64}" \
    '{($p):{SLSA:{buildDefinition:{externalParameters:{request:{root:{request:{args:{"vcs:source":$s,"vcs:revision":$r,"label:org.opencontainers.image.source":$s}}}}}}}}}'
}
prov ok  https://github.com/zeroroot-ai/zerocool-plugins     "$SHA" > "$tmp/good.json"
prov ok  https://github.com/zeroroot-ai/zerocool-plugins.git "$SHA" > "$tmp/good-git.json"
prov ok  https://github.com/zeroroot-ai/gibson               "$SHA" > "$tmp/wrong-repo.json"
prov ok  https://github.com/zeroroot-ai/zerocool-plugins     0000000000000000000000000000000000000000 > "$tmp/wrong-sha.json"
echo '{}'   > "$tmp/empty.json"
echo 'null' > "$tmp/null.json"
jq -n '{"linux/amd64":{SLSA:{buildDefinition:{externalParameters:{}}}}}' > "$tmp/no-vcs.json"
jq -s '.[0] * .[1]' "$tmp/good.json" <(prov x https://github.com/zeroroot-ai/gibson "$SHA" linux/arm64) > "$tmp/two-one-bad.json"

passes() { if out=$(check_provenance "$tmp/$1" zeroroot-ai/zerocool-plugins "$SHA" 2>&1); then ok; else bad "$2 was refused: $out"; fi; }
refuses() { if out=$(check_provenance "$tmp/$1" zeroroot-ai/zerocool-plugins "$SHA" 2>&1); then bad "$2 was accepted"; else ok; grep -q "$3" <<<"$out" && ok || bad "$2: message '$out' lacks '$3'"; fi; }
passes  good.json        "a matching provenance"
passes  good-git.json    "a matching provenance with a .git suffix"
refuses wrong-repo.json  "the wrong repo"   "is not https://github.com/zeroroot-ai/zerocool-plugins"
refuses wrong-sha.json   "the wrong commit" "revision"
refuses empty.json       "an index with no provenance" "no build provenance"
refuses null.json        "a null provenance" "no build provenance"
refuses no-vcs.json      "provenance without VCS fields" "source"
refuses two-one-bad.json "two platforms, one from the wrong repo" "linux/arm64"

echo "== SBOM: accepts an SPDX statement, refuses what cosign v3.0.6 produced =="
stmt() { jq -cn "$1" | base64 -w0 | jq -cR '{payloadType:"application/vnd.in-toto+json", payload:., signatures:[]}'; }
stmt '{predicateType:"https://spdx.dev/Document", predicate:{spdxVersion:"SPDX-2.3", packages:[{},{},{}]}}' > "$tmp/sbom-ok.json"
stmt '{predicateType:"https://sigstore.dev/cosign/sign/v1", predicate:{}}' > "$tmp/sbom-mislabeled.json"
stmt '{predicateType:"https://spdx.dev/Document", predicate:{}}' > "$tmp/sbom-empty.json"
: > "$tmp/sbom-none.json"
if out=$(check_sbom "$tmp/sbom-ok.json" 2>&1); then ok; grep -q "SPDX-2.3, 3 packages" <<<"$out" && ok || bad "sbom summary was '$out'"; else bad "a good SBOM was refused: $out"; fi
if check_sbom "$tmp/sbom-mislabeled.json" >/dev/null 2>&1; then bad "a cosign/sign/v1 predicate was accepted as an SBOM"; else ok; fi
if check_sbom "$tmp/sbom-empty.json"      >/dev/null 2>&1; then bad "an SPDX statement with no version was accepted"; else ok; fi
if check_sbom "$tmp/sbom-none.json"       >/dev/null 2>&1; then bad "no attestation at all was accepted"; else ok; fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
