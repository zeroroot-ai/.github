#!/usr/bin/env bash
# Scans every .github/workflows/*.y[a]ml under $1 (default .) and rejects any
# `runs-on:` label that is not sanctioned by ADR-0060.
#
# SANCTIONED
#   ubuntu-*        GitHub-hosted.
#   *-ephemeral     an ARC scale-set. Ephemeral by construction —
#                   JIT-registered, restartPolicy: Never, one job per pod,
#                   minRunners: 0 — which is the property ADR-0060 is about.
#
# An expression is normalised to a wildcard before matching, so a per-env
# selector like `${{ inputs.env }}-ephemeral` is judged on its SUFFIX. The env
# half is not the safety-relevant half; requiring it to be literal only forced
# callers to duplicate a job per environment. A BARE `${{ ... }}` with no
# `-ephemeral` suffix stays forbidden: that is an unbounded label and this
# guard can say nothing about what it resolves to.
#
# Extracted from .github/workflows/runs-on-lint.yml so scripts/test-runs-on-lint.sh
# can exercise the real classifier rather than a copy of it.
set -euo pipefail

root="${1:-.}"
violations=0

classify() {
  # Normalise any ${{ ... }} to X, then match on shape.
  local probe
  probe="$(echo "$1" | sed -E 's/\$\{\{[^}]*\}\}/X/g')"
  case "$probe" in
    ubuntu-*)    return 0 ;;
    *-ephemeral) return 0 ;;
    *)           return 1 ;;
  esac
}

# Exported for the test harness.
if [ "${RUNS_ON_LINT_CLASSIFY_ONLY:-}" = "1" ]; then
  classify "$2"; exit $?
fi

while IFS= read -r -d '' f; do
  while IFS= read -r line; do
    # Strip the `runs-on:` key, then array brackets/quotes, so both
    # `runs-on: ubuntu-latest` and `runs-on: [self-hosted, x]` parse alike.
    val="$(echo "$line" | sed -E 's/^[[:space:]]*runs-on:[[:space:]]*//')"
    val="$(echo "$val" | tr -d '[]"'"'"'')"
    IFS=',' read -ra labels <<< "$val"
    for raw in "${labels[@]}"; do
      label="$(echo "$raw" | xargs)"
      [ -z "$label" ] && continue
      if ! classify "$label"; then
        echo "::error file=$f::runs-on label '$label' is not sanctioned — only ubuntu-* (GitHub-hosted) or an *-ephemeral ARC scale-set are allowed. A bare \${{ }} expression with no -ephemeral suffix is an unbounded label and is rejected. See ADR-0060 (zeroroot-ai/docs)."
        violations=$((violations+1))
      fi
    done
  done < <(grep -E '^[[:space:]]*runs-on:' "$f" 2>/dev/null || true)
done < <(find "$root" -path ./.git -prune -o \
               \( -path '*/.github/workflows/*.yml' -o -path '*/.github/workflows/*.yaml' \) \
               -print0 2>/dev/null)

if [ "$violations" -gt 0 ]; then
  echo "::error::$violations forbidden runs-on label(s) found — no persistent self-hosted runners are permitted anywhere in the org (ADR-0060)."
  exit 1
fi
echo "OK: every runs-on label is ubuntu-* or an *-ephemeral ARC scale-set."
