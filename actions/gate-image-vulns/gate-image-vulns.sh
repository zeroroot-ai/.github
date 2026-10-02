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
#   * HIGH and CRITICAL block. MEDIUM stays visible and non-blocking.
#
# Because there is no hatch, the failure message is the whole ergonomics of
# this gate. It names the package, what is installed, what fixes it, and the
# one change that clears the block. A developer should never have to open the
# scanner's docs to act on it.
set -euo pipefail

report="${1:?usage: $0 <trivy-json> [severities] [reachability-dir]}"
severities="${2:-HIGH,CRITICAL}"
# reachdir holds the REACHABILITY EVIDENCE the action gathered for vendored
# binaries, one file per binary (see the block below). Empty means no binary was
# declared vendored, and this script then behaves exactly as it always has.
reachdir="${3:-}"

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

# ---------------------------------------------------------------------------
# Vendored binaries: the gate must ask reachability, not staleness.
# ---------------------------------------------------------------------------
# A Go stdlib finding is a VERSION COMPARISON: the binary's Go is behind a patch
# that fixed something. For a binary WE build that is the right question, because
# the remedy is to bump Go and we control that.
#
# For a vendored third-party binary it is the wrong question and there is no
# remedy at all. gVisor is the case that proved it: every artifact upstream
# publishes — release, nightly, GitHub, the GCS bucket — is built with go1.26.3,
# because MODULE.bazel pins the Go SDK from their own go.mod. Eleven fixable HIGH
# stdlib findings, none of them evidence that gVisor calls the affected code, and
# nothing setec could do about any of them. That is not a gate, it is a wall, and
# the paragraph at the bottom of this script used to say so and then shrug.
#
# So for a declared vendored binary the action runs `govulncheck -mode=binary`,
# which reports a vulnerability only when the affected SYMBOL is present in the
# binary, and leaves its answer here. This is not an allowlist: there are no
# per-CVE entries, nothing to expire, and nothing to re-pin. The gate simply
# stops claiming something it never measured.
#
# Evidence layout, written by action.yml:
#   <reachdir>/<slug>.reachable  OSV and CVE ids govulncheck found, one per line
#   <reachdir>/<slug>.failed     present when the analysis did not run
#   <reachdir>/<slug>.path       the binary path this slug stands for
#
# An analysis that did not run is NOT a pass. A missing or failed evidence file
# blocks, loudly, because "no finding" and "no analysis" are indistinguishable to
# anything that reads only a result.
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

blocking=""
notreachable=""
if [ -n "$reachdir" ]; then
  while IFS=$'\t' read -r sev pkg have fix id target; do
    [ -n "${sev:-}" ] || continue
    sl="$(slug "$target")"
    if [ ! -e "${reachdir}/${sl}.path" ]; then
      # Not a declared vendored binary: unchanged treatment.
      blocking="${blocking}${sev}\t${pkg}\t${have}\t${fix}\t${id}\t${target}\n"
      continue
    fi
    if [ -e "${reachdir}/${sl}.failed" ]; then
      echo "::error::reachability analysis did not run for ${target}; refusing to treat an un-run analysis as a pass" >&2
      sed 's/^/    /' "${reachdir}/${sl}.failed" >&2 || true
      blocking="${blocking}${sev}\t${pkg}\t${have}\t${fix}\t${id}\t${target}\n"
      continue
    fi
    if [ -s "${reachdir}/${sl}.reachable" ] && grep -qxF "$id" "${reachdir}/${sl}.reachable"; then
      blocking="${blocking}${sev}\t${pkg}\t${have}\t${fix}\t${id}\t${target} [REACHABLE]\n"
    else
      notreachable="${notreachable}  ${sev} ${pkg} ${have} -> ${fix}  (${id}) in ${target}\n"
    fi
  done <<< "$rows"

  if [ -n "$notreachable" ]; then
    {
      echo ""
      echo "NOT REACHABLE in a vendored binary, so not blocking:"
      printf '%b' "$notreachable"
      echo ""
      echo "  Evidence: govulncheck -mode=binary found no affected symbol in the"
      echo "  binary. The stdlib is behind, which is a staleness fact about the"
      echo "  upstream publisher, not a vulnerability in this image."
      echo ""
    } >&2
  fi

  rows="$(printf '%b' "$blocking" | sed '/^$/d')"
  if [ -z "$rows" ]; then
    nr=$(printf '%b' "$notreachable" | sed '/^$/d' | wc -l | tr -d ' ')
    echo "PASS: no fixable ${severities} findings that reach code (${nr} unreachable in vendored binaries)."
    exit 0
  fi
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
  echo "    Raise it to the FIXED IN version above."
  echo ""
  echo "  A third-party binary you do NOT build"
  echo "    Declare it in the vendored-binaries input of this action. The gate"
  echo "    then runs govulncheck -mode=binary against it and blocks only on a"
  echo "    finding whose affected symbol is actually present. A row marked"
  echo "    [REACHABLE] above has already been through that check: the symbol IS"
  echo "    in the binary, so it blocks and declaring it again will not help."
  echo ""
} >&2
exit 1
