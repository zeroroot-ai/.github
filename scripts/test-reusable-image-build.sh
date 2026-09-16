#!/usr/bin/env bash
#
# test-reusable-image-build.sh — assert the STRUCTURE of the image-build job.
#
# THE FIXTURE THIS EXISTS FOR. On 2026-09-16 a new step was inserted into the
# middle of the `build` step's `with:` block. The file still parsed as valid
# YAML, so `yaml.safe_load` said fine — but `docker/build-push-action` silently
# lost `cache-from` and `cache-to`, the rest of `build-args` was swallowed into
# the new step's `image:` input, and every image build in the org failed with
# `invalid reference format`.
#
# A YAML syntax check cannot see that. This asserts the keys each step owns.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - "$@" <<'PY'
import sys, yaml

W = ".github/workflows/reusable-image-build.yml"
d = yaml.safe_load(open(W))
steps = d["jobs"]["build-and-push"]["steps"]
fails = []

def step_by(pred, what):
    for s in steps:
        if pred(s):
            return s
    fails.append(f"no step matched {what}")
    return None

build = step_by(lambda s: s.get("id") == "build", "id: build")
if build:
    w = build.get("with", {})
    # Every input the build step must own. A step spliced into this block
    # steals the keys below it, so losing any one of them is the signature.
    for key in ("context", "file", "platforms", "tags", "labels", "push",
                "provenance", "sbom", "build-args", "cache-from", "cache-to"):
        if key not in w:
            fails.append(f"build step lost `{key}` — a later step may be spliced into its `with:`")
    ba = w.get("build-args", "")
    if "inputs.build_args" not in ba:
        fails.append("build-args no longer passes inputs.build_args")
    if "GOTOOLCHAIN" not in ba:
        fails.append("build-args no longer passes the GOTOOLCHAIN line")
    # Without this, every apt/apk layer in the org silently reverts to the
    # cached upgrade from the day it was first built. That is invisible until a
    # CVE lands, and by then the image has shipped.
    if "APT_CACHE_BUST" not in ba:
        fails.append("build-args no longer passes APT_CACHE_BUST — apt/apk upgrades will be cached away")
    if "APT_CACHE_BUST" in ba and "github.run_id" not in ba:
        fails.append("APT_CACHE_BUST is passed but not from a per-run value, so it cannot bust anything")
    if w.get("cache-from") != "type=gha":
        fails.append(f"cache-from is {w.get('cache-from')!r}, expected 'type=gha'")

guard = step_by(lambda s: "verify-image-license" in str(s.get("uses", "")),
                "the verify-image-license step")
if guard:
    w = guard.get("with", {})
    extra = set(w) - {"image", "path"}
    if extra:
        fails.append(f"the licence guard received inputs it does not declare: {sorted(extra)}")
    img = w.get("image", "")
    if "steps.meta.outputs" not in img:
        fails.append(f"the licence guard's image is {img!r}, not derived from the meta step")
    if "\n" in img:
        fails.append("the licence guard's image spans lines — it absorbed a neighbouring value")

# The gate must sit between the local build and the push. If it drifts after
# the push, a vulnerable image reaches the registry and the gate is decoration.
def pos_id(step_id):
    """Index of the step with EXACTLY this id. Substring matching on `uses`
    once matched docker/setup-buildx-action for "build", which is how this
    very assertion first went red."""
    for i, s in enumerate(steps):
        if s.get("id") == step_id:
            return i
    return None
def pos_uses(frag):
    for i, s in enumerate(steps):
        if frag in str(s.get("uses", "")):
            return i
    return None
p_local, p_gate, p_push = pos_id("build-local"), pos_uses("gate-image-vulns"), pos_id("build")
if None in (p_local, p_gate, p_push):
    fails.append(f"the pre-push gate is incomplete: build-local={p_local} gate={p_gate} build={p_push}")
elif not (p_local < p_gate < p_push):
    fails.append(f"the gate is out of order: build-local={p_local} gate={p_gate} build={p_push} — it must run BETWEEN them")

bl = step_by(lambda s: s.get("id") == "build-local", "the local build step")
if bl:
    w = bl.get("with", {})
    if w.get("load") is not True:
        fails.append("build-local does not set load: true, so there is no local image to scan")
    if w.get("push") is not False:
        fails.append("build-local must not push — that is the whole point of scanning first")
    if "APT_CACHE_BUST" not in str(w.get("build-args", "")):
        fails.append("build-local does not pass APT_CACHE_BUST, so it scans a differently-built image than the one pushed")

sc = step_by(lambda s: s.get("id") == "scan", "the trivy scan step")
if sc:
    w = sc.get("with", {})
    if w.get("ignore-unfixed") is not True:
        fails.append("the scan does not ignore unfixed CVEs, so the gate would block on findings nobody can act on")
    if str(w.get("exit-code")) != "0":
        fails.append("the scan must exit 0 and let the gate script decide, so the failure message stays actionable")

lic = step_by(lambda s: "spdx-from-license" in str(s.get("uses", "")),
              "the spdx-from-license step")
if lic:
    extra = set(lic.get("with", {})) - {"path"}
    if extra:
        fails.append(f"the spdx step received inputs it does not declare: {sorted(extra)}")

# Every `uses:` in the file resolves to something real.
for s in steps:
    u = str(s.get("uses", ""))
    if u.startswith("zeroroot-ai/.github/actions/"):
        name = u.split("@")[0].split("/")[-1]
        import os
        if not os.path.isfile(f"actions/{name}/action.yml"):
            fails.append(f"step uses actions/{name}, which does not exist in this repo")

if fails:
    for f in fails:
        print(f"  FAIL: {f}")
    print(f"\npassed=0 failed={len(fails)}")
    sys.exit(1)
print("passed=all failed=0")
PY
