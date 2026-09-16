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

# MEDIUM does not block: the scorecard gates on HIGH/CRITICAL and the two must
# agree about what matters.
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
# what is installed and what fixes it.
out=$(bash "$S" "$tmp/high.json" 2>&1 || true)
for want in "libsqlite3-0" "3.46.1-7+deb13u1" "3.46.1-7+deb13u2" "CVE-2026-11822" "APT_CACHE_BUST" "no allowlist"; do
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

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
