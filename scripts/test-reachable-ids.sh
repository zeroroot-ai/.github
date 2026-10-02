#!/usr/bin/env bash
#
# test-reachable-ids.sh — the reachability extraction must read govulncheck's
# FINDINGS, not the advisory definitions it streams alongside them.
#
# No network, no docker, no govulncheck. Crafted JSON only. That is the whole
# point: the first version of this extraction shipped untested because the
# collector around it needs docker and a vulnerability database, and the jq in the
# middle of it needs neither.
set -euo pipefail
cd "$(dirname "$0")/.."

JQF=actions/gate-image-vulns/reachable-ids.jq
PASS=0 FAIL=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

run() { jq -r -n -f "$JQF" < "$1" | LC_ALL=C sort -u; }
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

# THE REGRESSION. A definition alone is not a finding. govulncheck emits one
# `osv` per advisory it loaded; treating those as results returns the database.
cat > "$tmp/defs-only.json" <<'J'
{"config":{"scanner_name":"govulncheck"}}
{"osv":{"id":"GO-2026-0001","aliases":["CVE-2026-27145"]}}
{"osv":{"id":"GO-2026-0002","aliases":["CVE-2026-33818"]}}
{"osv":{"id":"GO-2026-0003","aliases":["CVE-2026-56862"]}}
J
got=$(run "$tmp/defs-only.json")
if [ -z "$got" ]; then ok; else bad "advisory definitions with no finding returned: $(echo "$got" | tr '\n' ' ')"; fi

# A finding IS reported, and its CVE alias comes with it, because the image
# scanner names CVEs and govulncheck names GO ids.
cat > "$tmp/one-finding.json" <<'J'
{"osv":{"id":"GO-2026-0001","aliases":["CVE-2026-27145"]}}
{"osv":{"id":"GO-2026-0002","aliases":["CVE-2026-33818"]}}
{"finding":{"osv":"GO-2026-0002","trace":[{"module":"stdlib","function":"Read"}]}}
J
got=$(run "$tmp/one-finding.json")
want=$'CVE-2026-33818\nGO-2026-0002'
if [ "$got" = "$want" ]; then ok; else bad "one finding gave [$(echo "$got" | tr '\n' ' ')], want CVE-2026-33818 GO-2026-0002"; fi

# A module-level finding — no function in the trace — still counts. govulncheck
# could not rule the vulnerability out, and a gate must not read "could not tell"
# as "not present".
cat > "$tmp/module-level.json" <<'J'
{"osv":{"id":"GO-2026-0007","aliases":["CVE-2026-46600"]}}
{"finding":{"osv":"GO-2026-0007","trace":[{"module":"stdlib"}]}}
J
got=$(run "$tmp/module-level.json")
# A HERESTRING, not a pipe into `grep -q`. Under `set -o pipefail` grep -q exits
# as soon as it matches, printf then takes SIGPIPE, and the PIPELINE reports
# failure on a successful match. This assertion failed for a passing extraction
# until the pipe went away — the same shape as a `tail` swallowing an exit code.
if grep -qx 'CVE-2026-46600' <<<"$got"; then ok; else bad "a module-level finding was dropped: [$got]"; fi

# A finding whose advisory has no aliases still reports its GO id.
cat > "$tmp/no-alias.json" <<'J'
{"osv":{"id":"GO-2026-0009"}}
{"finding":{"osv":"GO-2026-0009","trace":[{"module":"example.com/x","function":"F"}]}}
J
got=$(run "$tmp/no-alias.json")
if [ "$got" = "GO-2026-0009" ]; then ok; else bad "a finding with no aliases gave [$got]"; fi

# A finding for an advisory that was never defined must not be lost.
cat > "$tmp/undefined.json" <<'J'
{"finding":{"osv":"GO-2026-9999","trace":[{"module":"stdlib","function":"G"}]}}
J
got=$(run "$tmp/undefined.json")
if [ "$got" = "GO-2026-9999" ]; then ok; else bad "a finding with no matching definition gave [$got]"; fi

# Duplicate findings for one advisory collapse to one id.
cat > "$tmp/dupes.json" <<'J'
{"osv":{"id":"GO-2026-0002","aliases":["CVE-2026-33818"]}}
{"finding":{"osv":"GO-2026-0002","trace":[{"module":"stdlib","function":"A"}]}}
{"finding":{"osv":"GO-2026-0002","trace":[{"module":"stdlib","function":"B"}]}}
J
n=$(run "$tmp/dupes.json" | wc -l | tr -d ' ')
if [ "$n" = "2" ]; then ok; else bad "two findings for one advisory gave $n ids, want 2 (the GO id and its alias)"; fi

# Progress and config lines must not become ids.
cat > "$tmp/noise.json" <<'J'
{"config":{"scanner_name":"govulncheck","scanner_version":"v1.1.4"}}
{"progress":{"message":"Scanning your binary for known vulnerabilities..."}}
J
got=$(run "$tmp/noise.json")
if [ -z "$got" ]; then ok; else bad "config/progress lines produced ids: [$got]"; fi

# An empty stream is empty, not an error.
: > "$tmp/empty.json"
if got=$(run "$tmp/empty.json") && [ -z "$got" ]; then ok; else bad "an empty stream did not yield an empty set"; fi

echo "passed=$PASS failed=$FAIL"
# A FLOOR, at the END of the file. Six fixtures in a sibling harness silently
# never ran because they were appended below its summary line.
if [ "$PASS" -lt 8 ] && [ "$FAIL" -eq 0 ]; then
  echo "FAIL: only $PASS case(s) ran" >&2
  exit 1
fi
[ "$FAIL" -eq 0 ]
echo "✅ reachable-ids: $PASS cases — findings count, definitions do not"
