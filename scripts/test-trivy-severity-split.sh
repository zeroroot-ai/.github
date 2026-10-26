#!/usr/bin/env bash
#
# test-trivy-severity-split.sh — the image scans report every severity and
# gate on HIGH and CRITICAL only (.github#296).
#
# THE DEFECT THIS EXISTS FOR. .github#293 set limit-severities-for-sarif on the
# one Trivy step that wrote both the SARIF and the verdict. The false failures
# on LOW and MEDIUM findings stopped, but code scanning then got only HIGH and
# CRITICAL, and real MEDIUM alerts retired as "fixed" with no fix
# (zitadel-login alerts 84-94). Before .github#293, the opposite defect: the
# SARIF held every severity, so exit-code 1 failed on any LOW finding.
#
# The fix splits the two: one JSON scan, then `trivy convert` makes a SARIF
# with every severity, a table, and a gate with the gate severities. This test
# reads both reusable workflows and fails when:
#   - a step sets limit-severities-for-sarif, or the JSON scan narrows its
#     severities or can fail;
#   - the SARIF block of reusable-image-build drops a severity: it runs the
#     block on tests/fixtures/trivy/report-with-high.json and counts results;
#   - a gate block passes a HIGH finding or fails on LOW and MEDIUM only: it
#     runs the block on both fixture reports;
#   - a gate block passes a HIGH embedded secret (report-with-secret.json);
#   - the table block does not name the HIGH finding or the HIGH secret.
# It then plants each defect in a copy of the workflows and proves that the
# check fails on it. A check that cannot fail is worse than none.
#
# It runs `trivy` from PATH, or from $TRIVY. With no trivy it fails: a green
# run must prove it ran the blocks.
set -euo pipefail
cd "$(dirname "$0")/.."

TRIVY="${TRIVY:-$(command -v trivy || true)}"
if [ -z "$TRIVY" ] || [ ! -x "$TRIVY" ]; then
  echo "FAIL: no trivy binary. Put it on PATH or set TRIVY." >&2
  exit 1
fi
export TRIVY

python3 - <<'PY'
import os, re, subprocess, sys, tempfile, json
import yaml

TRIVY = os.environ["TRIVY"]
FIX = "tests/fixtures/trivy"
LOW_MED = f"{FIX}/report-low-medium.json"
WITH_HIGH = f"{FIX}/report-with-high.json"
WITH_SECRET = f"{FIX}/report-with-secret.json"
SECRET_RULE = "github-pat"
HIGH_ID = "CVE-2022-4450"
FILES = {
    "image-build": (".github/workflows/reusable-image-build.yml", "vuln-scan"),
    "verify-release": (".github/workflows/reusable-verify-release.yml", "verify"),
}
ALL = {"UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL"}


def block(text, name):
    m = re.search(rf"# BEGIN-{name}[^\n]*\n(.*?)\n\s*# END-{name}", text, re.S)
    return m.group(1) if m else None


def run_block(code, env):
    """Run one extracted block with trivy on PATH. Returns the exit code."""
    d = os.path.dirname(os.path.abspath(TRIVY))
    e = dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"], **env)
    return subprocess.run(["bash", "-c", "set -euo pipefail\n" + code], env=e,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode


def check(texts):
    """Every defect found in the two workflow texts, as a list of strings."""
    fails = []
    for key, (path, job) in FILES.items():
        text = texts[key]
        steps = yaml.safe_load(text)["jobs"][job]["steps"]
        for s in steps:
            if "limit-severities-for-sarif" in (s.get("with") or {}):
                fails.append(f"{key}: a step sets limit-severities-for-sarif")
        scans = [s for s in steps if "trivy-action" in str(s.get("uses", ""))]
        if len(scans) != 1:
            fails.append(f"{key}: {len(scans)} trivy-action steps, want one scan")
        for s in scans:
            w = s.get("with") or {}
            if w.get("format") != "json":
                fails.append(f"{key}: the scan writes {w.get('format')!r}, not one JSON report")
            if str(w.get("exit-code")) != "0":
                fails.append(f"{key}: the scan can fail; only the gate may fail")
            sev = w.get("severity")
            if sev and set(str(sev).split(",")) != ALL:
                fails.append(f"{key}: the scan narrows its severities to {sev}")

        gate = block(text, "TRIVY-GATE")
        gate_step = next((s for s in steps if "BEGIN-TRIVY-GATE" in str(s.get("run", ""))), None)
        if gate is None or gate_step is None:
            fails.append(f"{key}: no gate block")
        else:
            sev = str((gate_step.get("env") or {}).get("GATE_SEVERITY", ""))
            if key == "image-build":
                doc = yaml.safe_load(text)
                on = doc.get("on", doc.get(True))  # YAML 1.1 reads `on` as true
                default = on["workflow_call"]["inputs"]["trivy_severity"]["default"]
                sev = sev.replace("${{ inputs.trivy_severity }}", default)
            if sev != "HIGH,CRITICAL":
                fails.append(f"{key}: the gate severity is {sev!r}, not HIGH,CRITICAL")
            if gate_step.get("continue-on-error") or "always()" in str(gate_step.get("if", "")):
                fails.append(f"{key}: the gate step is not a plain failing step")
            if steps.index(gate_step) != len(steps) - 1 and key == "verify-release":
                fails.append(f"{key}: the gate is not the last step")
            env = {"GATE_SEVERITY": sev}
            if run_block(gate, dict(env, REPORT=WITH_HIGH)) == 0:
                fails.append(f"{key}: the gate passed a report with a HIGH finding")
            if run_block(gate, dict(env, REPORT=WITH_SECRET)) == 0:
                fails.append(f"{key}: the gate passed a report with a HIGH secret")
            if run_block(gate, dict(env, REPORT=LOW_MED)) != 0:
                fails.append(f"{key}: the gate failed a report with only LOW and MEDIUM findings")

        table = block(text, "TRIVY-TABLE")
        if table is None:
            fails.append(f"{key}: no table block")
        else:
            with tempfile.TemporaryDirectory() as t:
                out = os.path.join(t, "table.txt")
                rc = run_block(table, {"REPORT": WITH_HIGH, "TABLE": out, "SEVERITY": "HIGH,CRITICAL"})
                if rc != 0 or HIGH_ID not in open(out).read():
                    fails.append(f"{key}: the table does not name the HIGH finding {HIGH_ID}")
                rc = run_block(table, {"REPORT": WITH_SECRET, "TABLE": out, "SEVERITY": "HIGH,CRITICAL"})
                if rc != 0 or SECRET_RULE not in open(out).read():
                    fails.append(f"{key}: the table does not name the HIGH secret {SECRET_RULE}")

        if key == "image-build":
            sarif = block(text, "TRIVY-SARIF")
            if sarif is None:
                fails.append(f"{key}: no SARIF block")
            else:
                with tempfile.TemporaryDirectory() as t:
                    out = os.path.join(t, "r.sarif")
                    rc = run_block(sarif, {"REPORT": WITH_HIGH, "SARIF": out})
                    n = len(json.load(open(out))["runs"][0]["results"]) if rc == 0 and os.path.exists(out) else -1
                    if n != 3:
                        fails.append(f"{key}: the SARIF holds {n} of the 3 findings (LOW, MEDIUM, HIGH)")
            up = [s for s in steps if "upload-sarif" in str(s.get("uses", ""))]
            if not up or not str((up[0].get("with") or {}).get("sarif_file", "")).endswith(".sarif"):
                fails.append(f"{key}: no upload-sarif step sends the SARIF report")
    return fails


real = {k: open(p).read() for k, (p, _) in FILES.items()}
failed = False

found = check(real)
if found:
    failed = True
    for f in found:
        print(f"  FAIL: {f}")
else:
    print("  ok: both workflows report every severity and gate on HIGH and CRITICAL")

# Planted defects. Each mutant must make check() report the named defect.
MUTANTS = [
    ("the SARIF limits severities", "image-build",
     'trivy convert --format sarif --output "$SARIF" "$REPORT"',
     'trivy convert --format sarif --severity HIGH,CRITICAL --output "$SARIF" "$REPORT"',
     "the SARIF holds"),
    ("the scan sets limit-severities-for-sarif", "image-build",
     "          output: trivy-${{ inputs.component_name }}.json\n",
     "          output: trivy-${{ inputs.component_name }}.json\n          limit-severities-for-sarif: true\n",
     "limit-severities-for-sarif"),
    ("the image-build gate stops failing", "image-build",
     '--exit-code 1 --output /dev/null "$REPORT"',
     '--exit-code 0 --output /dev/null "$REPORT"',
     "passed a report with a HIGH finding"),
    ("the verify-release gate stops failing", "verify-release",
     '--exit-code 1 --output /dev/null "$REPORT"',
     '--exit-code 0 --output /dev/null "$REPORT"',
     "passed a report with a HIGH finding"),
    ("the verify-release gate fails on MEDIUM", "verify-release",
     "          GATE_SEVERITY: HIGH,CRITICAL\n",
     "          GATE_SEVERITY: MEDIUM,HIGH,CRITICAL\n",
     "not HIGH,CRITICAL"),
]
for name, key, old, new, want in MUTANTS:
    if real[key].count(old) != 1:
        failed = True
        print(f"  FAIL: fixture '{name}': the text it plants into is not in {key} exactly once")
        continue
    texts = dict(real)
    texts[key] = real[key].replace(old, new)
    got = check(texts)
    if any(want in f for f in got):
        print(f"  ok: fixture '{name}' is caught")
    else:
        failed = True
        print(f"  FAIL: fixture '{name}' was not caught (got {got})")

sys.exit(1 if failed else 0)
PY
