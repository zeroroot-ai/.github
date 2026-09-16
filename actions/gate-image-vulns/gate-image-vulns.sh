#!/usr/bin/env bash
#
# gate-image-vulns.sh <trivy.json> [severities] — decide whether an image may
# be pushed, and say exactly what to do when it may not.
#
# Owner decision 2026-09-16, three parts:
#
#   * The scan runs BEFORE the push. A vulnerable image never reaches the
#     registry, rather than being caught a day later by the board.
#   * There is NO escape hatch. No .trivyignore, no expiring allowlist, no
#     per-repo opt-out. The only ways past a block are fixing the CVE or
#     bumping the base.
#   * HIGH and CRITICAL block. MEDIUM stays visible and non-blocking, matching
#     what the launch scorecard gates on, so the board and the build agree
#     about what matters.
#
# Because there is no hatch, the failure message is the whole ergonomics of
# this gate. It names the package, what is installed, what fixes it, and the
# one change that clears the block. A developer should never have to open the
# scanner's docs to act on it.
set -euo pipefail

report="${1:?usage: $0 <trivy-json> [severities]}"
severities="${2:-HIGH,CRITICAL}"

[ -f "$report" ] || { echo "::error::no scan report at ${report}"; exit 1; }

# Only findings WITH a published fix. An unfixed CVE has no action a repo can
# take, and blocking on one would be a hostage situation rather than a gate.
rows=$(jq -r --arg sev "$severities" '
  ($sev | ascii_upcase | split(",")) as $want
  | [ (.Results // [])[]
      | .Target as $t
      | (.Vulnerabilities // [])[]
      | select(.Severity as $s | $want | index($s))
      | select((.FixedVersion // "") != "")
      | { t: $t, id: .VulnerabilityID, pkg: .PkgName,
          have: (.InstalledVersion // "?"), fix: .FixedVersion, sev: .Severity } ]
  | unique_by([.pkg, .id])
  | .[] | [.sev, .pkg, .have, .fix, .id, .t] | @tsv
' "$report")

if [ -z "$rows" ]; then
  echo "PASS: no fixable ${severities} findings."
  exit 0
fi

n=$(printf '%s\n' "$rows" | wc -l)
{
  echo ""
  echo "BLOCKED: ${n} fixable ${severities} finding(s). This image is not pushed."
  echo ""
  printf '  %-9s %-28s %-24s %s\n' SEVERITY PACKAGE INSTALLED "FIXED IN"
  printf '%s\n' "$rows" | while IFS=$'\t' read -r sev pkg have fix id target; do
    printf '  %-9s %-28s %-24s %s   (%s)\n' "$sev" "$pkg" "$have" "$fix" "$id"
  done
  echo ""
  echo "There is no allowlist and no opt-out, by decision. Two things clear it:"
  echo ""
  echo "  OS package (apt/apk)"
  echo "    The fix is already published, so the base is stale or the upgrade is"
  echo "    cached. Check the runtime stage runs \`apt-get upgrade\` / \`apk upgrade\`"
  echo "    AND declares \`ARG APT_CACHE_BUST\` before it — the org workflow passes"
  echo "    that arg to every build. If both are present, refresh the base digest."
  echo ""
  echo "  Language dependency (go/npm/...)"
  echo "    Raise it to the FIXED IN version above. If a third-party binary links"
  echo "    it and you do not build that binary, you cannot move it from here —"
  echo "    build it from source against a floor, or take it to the owner."
  echo ""
} >&2
exit 1
