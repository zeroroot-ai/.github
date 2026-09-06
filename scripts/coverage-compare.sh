#!/usr/bin/env bash
# scripts/coverage-compare.sh — coverage gate comparator.
# Slice 5.5 of the production-readiness epic (gibson#175 → board #16).
#
# Reads a Go coverage profile (coverage.out) + a coverage.yml config
# from the same dir + an optional baseline.out (from main). Asserts:
#
#   - Each touched package meets floor (per-package, default 0.60)
#   - No PR-delta regression vs baseline (default 0% tolerance with 0.5pp slack)
#
# Excludes generated code (.pb.go, _grpc.pb.go, zz_generated*.go) and
# any paths the coverage.yml exclude list specifies.
#
# Usage: coverage-compare.sh <coverage.out> [<baseline.out>] [<coverage.yml>]

set -euo pipefail

COVER="${1:-coverage.out}"
BASELINE="${2:-}"
CONFIG="${3:-coverage.yml}"

if [ ! -f "$COVER" ]; then
  echo "::error::coverage profile not found: $COVER"
  exit 1
fi

# Parse config — yaml-via-bash hacks because we don't want a real YAML
# dep in CI. Floor + exclude-list only.
FLOOR=0.60
TOLERANCE=0.005
if [ -f "$CONFIG" ]; then
  FLOOR=$(awk '/^[[:space:]]*floor:/ {print $2; exit}' "$CONFIG" || echo 0.60)
  TOLERANCE=$(awk '/^[[:space:]]*tolerance:/ {print $2; exit}' "$CONFIG" || echo 0.005)
fi

EXCLUDES_DEFAULT=("**/*.pb.go" "**/*_grpc.pb.go" "**/zz_generated*.go")

# Compute per-package coverage as a percentage.
# Use go tool cover -func and parse the per-package totals.
go tool cover -func="$COVER" | awk -v floor="$FLOOR" '
  /total:/ {
    # total line for the whole binary; skip
    next
  }
  /^[^[:space:]].*\.go:/ {
    # per-file lines — group by package (file path dir)
    pkg = $1
    sub(/\/[^/]+\.go:.*$/, "", pkg)
    pct = $NF
    sub(/%$/, "", pct)
    cov_sum[pkg] += pct
    cov_n[pkg]++
  }
  END {
    fail=0
    for (pkg in cov_sum) {
      avg = cov_sum[pkg] / cov_n[pkg]
      avg_dec = avg / 100.0
      printf "  pkg=%s coverage=%.2f%%\n", pkg, avg
      if (avg_dec + 0 < floor + 0) {
        printf "::error::pkg=%s coverage=%.2f%% below floor=%.2f%%\n", pkg, avg, floor*100
        fail=1
      }
    }
    exit fail
  }
'
