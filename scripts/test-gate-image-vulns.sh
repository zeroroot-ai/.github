#!/usr/bin/env bash
#
# test-gate-image-vulns.sh — the gate must block a fixable HIGH, pass a clean
# image, and never block on something nobody can act on.
#
# No network, no docker. Crafted Trivy JSON only.
set -euo pipefail
cd "$(dirname "$0")/.."

S=actions/gate-image-vulns/gate-image-vulns.sh
PASS=0 FAIL=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mk() { cat > "$tmp/$1"; }
blocks()  { if bash "$S" "$tmp/$1" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "  FAIL: $2 was allowed"; else PASS=$((PASS+1)); fi; }
allows()  { if bash "$S" "$tmp/$1" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $2 was blocked"; fi; }

mk clean.json <<'J'
{"Results":[{"Target":"img (debian 13.6)","Vulnerabilities":[]}]}
J
allows clean.json "a clean image"

mk empty.json <<'J'
{"Results":null}
J
allows empty.json "a report with no results at all"

# THE FIXTURE THIS EXISTS FOR.
mk high.json <<'J'
{"Results":[{"Target":"img (debian 13.6)","Vulnerabilities":[
 {"VulnerabilityID":"CVE-2026-11822","PkgName":"libsqlite3-0","InstalledVersion":"3.46.1-7+deb13u1","FixedVersion":"3.46.1-7+deb13u2","Severity":"HIGH"}]}]}
J
blocks high.json "a fixable HIGH"

mk crit.json <<'J'
{"Results":[{"Target":"app/package-lock.json","Vulnerabilities":[
 {"VulnerabilityID":"CVE-2026-75604","PkgName":"next","InstalledVersion":"16.2.11","FixedVersion":"15.5.24, 16.3.3","Severity":"CRITICAL"}]}]}
J
blocks crit.json "a fixable CRITICAL"

# An unfixed CVE is not a hostage situation. Nobody can act on it, so it must
# not stop a release.
mk unfixed.json <<'J'
{"Results":[{"Target":"img","Vulnerabilities":[
 {"VulnerabilityID":"CVE-2026-99999","PkgName":"libfoo","InstalledVersion":"1.0","FixedVersion":"","Severity":"CRITICAL"}]}]}
J
allows unfixed.json "an UNFIXED critical"

# MEDIUM does not block: only HIGH and CRITICAL do.
mk medium.json <<'J'
{"Results":[{"Target":"img","Vulnerabilities":[
 {"VulnerabilityID":"CVE-2026-5450","PkgName":"libc6","InstalledVersion":"2.41-12+deb13u3","FixedVersion":"2.41-12+deb13u4","Severity":"MEDIUM"}]}]}
J
allows medium.json "a fixable MEDIUM"

# ...but it does when asked for explicitly, so the setting is real.
if bash "$S" "$tmp/medium.json" "MEDIUM,HIGH,CRITICAL" >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "  FAIL: MEDIUM was allowed even when named in the severity list"
else PASS=$((PASS+1)); fi

# The message is the ergonomics: with no escape hatch, it must name the package,
# what is installed, what fixes it, and WHICH TARGET. The target was missing, and
# eleven `stdlib v1.26.3` rows with no target made setec's installer failure
# undiagnosable from the log.
out=$(bash "$S" "$tmp/high.json" 2>&1 || true)
for want in "libsqlite3-0" "3.46.1-7+deb13u1" "3.46.1-7+deb13u2" "CVE-2026-11822" "APT_CACHE_BUST" "no allowlist" "img (debian 13.6)" "TARGET"; do
  case "$out" in
    *"$want"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: the failure message never mentions '$want'" ;;
  esac
done

# A missing report is a failure, not a pass. A scan that did not run must never
# look like a clean one.
if bash "$S" "$tmp/does-not-exist.json" >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "  FAIL: a missing report was treated as clean"
else PASS=$((PASS+1)); fi

# One CVE reported against several targets is one finding, not three.
mk dupes.json <<'J'
{"Results":[
 {"Target":"a","Vulnerabilities":[{"VulnerabilityID":"CVE-1","PkgName":"p","InstalledVersion":"1","FixedVersion":"2","Severity":"HIGH"}]},
 {"Target":"b","Vulnerabilities":[{"VulnerabilityID":"CVE-1","PkgName":"p","InstalledVersion":"1","FixedVersion":"2","Severity":"HIGH"}]}]}
J
n=$(bash "$S" "$tmp/dupes.json" 2>&1 | grep -c "CVE-1" || true)
if [ "$n" -eq 1 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: one CVE across two targets listed $n times"; fi


# ---------------------------------------------------------------------------
# Vendored binaries: reachability, not staleness.
# ---------------------------------------------------------------------------
# The gVisor case. A Go stdlib finding on a binary we do not build is a version
# comparison with no remedy: every artifact upstream publishes is built with the
# Go their own go.mod names. The gate must ask whether the affected symbol is in
# the binary, and these cases are what stop it going back to asking staleness.
slug() {
  printf '%s' "$1" \
    | sed -e 's#^\./##' -e 's#^/\+##' -e 's#/\+$##' \
    | tr -c 'A-Za-z0-9._-' '_'
}

# evidence <reachdir> <binary-path> <failed|ok> [reachable-id ...]
evidence() {
  local d="$1" path="$2" state="$3"; shift 3
  mkdir -p "$d"
  local sl; sl="$(slug "$path")"
  printf '%s\n' "$path" > "$d/${sl}.path"
  if [ "$state" = failed ]; then
    printf 'govulncheck exited 1: could not load binary\n' > "$d/${sl}.failed"
  else
    : > "$d/${sl}.reachable"
    local id
    for id in "$@"; do printf '%s\n' "$id" >> "$d/${sl}.reachable"; done
  fi
}

blocks_r() { if bash "$S" "$tmp/$1" HIGH,CRITICAL "$2" >/dev/null 2>&1; then FAIL=$((FAIL+1)); echo "  FAIL: $3 was allowed"; else PASS=$((PASS+1)); fi; }
allows_r() { if bash "$S" "$tmp/$1" HIGH,CRITICAL "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $3 was blocked"; fi; }

mk vendored.json <<'J'
{"Results":[{"Target":"opt/gvisor/runsc","Vulnerabilities":[
 {"VulnerabilityID":"CVE-2026-27145","PkgName":"stdlib","InstalledVersion":"v1.26.3","FixedVersion":"1.26.4","Severity":"HIGH"},
 {"VulnerabilityID":"CVE-2026-33818","PkgName":"stdlib","InstalledVersion":"v1.26.3","FixedVersion":"1.26.6","Severity":"HIGH"}]}]}
J

# 1. Neither affected symbol is in the binary: the image ships.
evidence "$tmp/r_none" opt/gvisor/runsc ok
allows_r vendored.json "$tmp/r_none" "a vendored stdlib finding with no reachable symbol"

# 2. One IS reachable: it blocks. This is the case that keeps the gate a gate.
evidence "$tmp/r_one" opt/gvisor/runsc ok CVE-2026-33818
blocks_r vendored.json "$tmp/r_one" "a vendored stdlib finding whose symbol IS present"

# 3. The analysis did not run. Blocking is the only safe answer: "no finding"
#    and "no analysis" are indistinguishable to anything reading only a result,
#    and treating the second as a pass is how a gate stops being one.
evidence "$tmp/r_fail" opt/gvisor/runsc failed
blocks_r vendored.json "$tmp/r_fail" "a vendored binary whose reachability analysis failed"

# 4. A declaration for ONE binary must not soften the verdict on another. The
#    OS-package finding below is on a different target and still blocks.
mk mixed.json <<'J'
{"Results":[
 {"Target":"opt/gvisor/runsc","Vulnerabilities":[
  {"VulnerabilityID":"CVE-2026-27145","PkgName":"stdlib","InstalledVersion":"v1.26.3","FixedVersion":"1.26.4","Severity":"HIGH"}]},
 {"Target":"img (debian 13.6)","Vulnerabilities":[
  {"VulnerabilityID":"CVE-2026-11822","PkgName":"libsqlite3-0","InstalledVersion":"3.46.1-7","FixedVersion":"3.46.1-8","Severity":"HIGH"}]}]}
J
evidence "$tmp/r_mixed" opt/gvisor/runsc ok
blocks_r mixed.json "$tmp/r_mixed" "an OS finding beside an unreachable vendored one"

# 5. A finding on a binary that was NOT declared vendored keeps the old
#    treatment even when a reachability dir exists for something else.
mk undeclared.json <<'J'
{"Results":[{"Target":"usr/local/bin/setec","Vulnerabilities":[
 {"VulnerabilityID":"CVE-2026-27145","PkgName":"stdlib","InstalledVersion":"v1.26.3","FixedVersion":"1.26.4","Severity":"HIGH"}]}]}
J
blocks_r undeclared.json "$tmp/r_none" "a finding on a binary nobody declared vendored"

# 6. And with no reachability dir at all, the gate is exactly what it was.
blocks vendored.json "a vendored finding with no reachability dir"

# 7. A target that does not equal any declared path falls through to the
#    unchanged treatment, which is correct — but it must be VISIBLE. The gate
#    prints the declarations it holds evidence for and the target of every
#    blocking row, so the mismatch can be read off the log instead of guessed at.
#    This is the case that cost a diagnosis cycle on setec's installer.
evidence "$tmp/r_mismatch" opt/gvisor/runsc ok
mk mismatched-target.json <<'J'
{"Results":[{"Target":"payload/opt/gvisor/runsc","Vulnerabilities":[
 {"VulnerabilityID":"CVE-2026-27145","PkgName":"stdlib","InstalledVersion":"v1.26.3","FixedVersion":"1.26.4","Severity":"HIGH"}]}]}
J
out=$(bash "$S" "$tmp/mismatched-target.json" HIGH,CRITICAL "$tmp/r_mismatch" 2>&1 || true)
for want in "payload/opt/gvisor/runsc" "Vendored binaries with reachability evidence" "opt/gvisor/runsc"; do
  case "$out" in
    *"$want"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: a target/declaration mismatch does not show '$want'" ;;
  esac
done


# 8. PATH SPELLING MUST NOT DECIDE THE VERDICT. The declaration and the scanner's
#    target are two independently produced strings for one file, and which of
#    "opt/x", "/opt/x" or "./opt/x" a scanner emits is not a documented contract.
#    setec's installer blocked all eleven of its findings with no [REACHABLE] mark
#    and no not-reachable line, because no slug matched — the failure this case
#    exists to make impossible.
evidence "$tmp/r_norm" opt/gvisor/runsc ok
for variant in "opt/gvisor/runsc" "/opt/gvisor/runsc" "./opt/gvisor/runsc" "opt/gvisor/runsc/"; do
  cat > "$tmp/variant.json" <<J
{"Results":[{"Target":"${variant}","Vulnerabilities":[
 {"VulnerabilityID":"CVE-2026-27145","PkgName":"stdlib","InstalledVersion":"v1.26.3","FixedVersion":"1.26.4","Severity":"HIGH"}]}]}
J
  if bash "$S" "$tmp/variant.json" HIGH,CRITICAL "$tmp/r_norm" >/dev/null 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "  FAIL: target spelling '${variant}' did not match the declaration opt/gvisor/runsc"
  fi
done

# 9. ...and a genuinely different path still does NOT match, so the normalisation
#    did not turn the comparison into "anything goes".
cat > "$tmp/other.json" <<'J'
{"Results":[{"Target":"opt/gvisor/other-binary","Vulnerabilities":[
 {"VulnerabilityID":"CVE-2026-27145","PkgName":"stdlib","InstalledVersion":"v1.26.3","FixedVersion":"1.26.4","Severity":"HIGH"}]}]}
J
blocks_r other.json "$tmp/r_norm" "a finding on a path nobody declared"

echo
echo "passed=$PASS failed=$FAIL"
# A FLOOR. These cases are appended over time, and appending below this block is
# how six of them silently never ran: the summary and the exit line sat in the
# middle of the file, so everything after it was dead. The count is the guard
# against that happening again.
if [ "$PASS" -lt 30 ] && [ "$FAIL" -eq 0 ]; then
  echo "FAIL: only $PASS case(s) ran; cases were added below the summary block again" >&2
  exit 1
fi
[ "$FAIL" -eq 0 ]
