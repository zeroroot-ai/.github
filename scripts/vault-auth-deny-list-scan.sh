#!/usr/bin/env bash
# vault-auth-deny-list-scan.sh
#
# Scans the calling-repo's source tree for ADR-0009 deny-list tokens.
#
# Source of truth: zero-day-ai/docs / adr/0009-jwt-spiffe-everywhere.md
# The "### Deny-list" Markdown table is parsed at workflow run time so the
# scanner and the ADR cannot diverge.
#
# Tokens are extracted from the first column of the deny-list table:
# every backtick-wrapped string in a `|` row becomes a deny-list entry.
# Rows whose first column is pure prose (no backticks) are skipped — they
# describe *patterns* that need structural review rather than literal-string
# rejection (e.g. "Any HTTP POST to Vault `/v1/auth/jwt/login` carrying a
# Zitadel-issued JWT" — `/v1/auth/jwt/login` alone is legitimate).
#
# Exits 0 when clean, 1 on any violation outside the allowlist.
#
# Modes:
#   (default)                     scan, fail on any violation outside allowlist
#   --selftest                    synthesise one temp file per deny-list
#                                 token, assert scanner catches each, exit 0
#                                 on success.
#
# Inputs (env vars):
#   ADR_PATH      Path to the ADR file (defaults to ./docs-repo/adr/0009-jwt-spiffe-everywhere.md)
#   REPO_ROOT     Path to the calling repo's checkout (defaults to $GITHUB_WORKSPACE or .)
#   ALLOWLIST     Path to the allowlist JSON (defaults to $REPO_ROOT/.github/.vault-auth-deny-list-allowlist.json)
#
# The allowlist file is a JSON array of {file, line, token} objects.
# Monotonic-shrink: any entry whose source line no longer contains the
# token is treated as stale and fails the run (with a hint to remove it).
# New violations are never auto-allowlisted; reviewers must hand-edit the
# JSON to add an entry (forcing a conversation about why the exception
# is legitimate).

set -euo pipefail

ADR_PATH="${ADR_PATH:-./docs-repo/adr/0009-jwt-spiffe-everywhere.md}"
REPO_ROOT="${REPO_ROOT:-${GITHUB_WORKSPACE:-.}}"
ALLOWLIST="${ALLOWLIST:-$REPO_ROOT/.github/.vault-auth-deny-list-allowlist.json}"
ADR_URL="https://github.com/zero-day-ai/docs/blob/main/adr/0009-jwt-spiffe-everywhere.md"

MODE="${1:-scan}"

# ---------------------------------------------------------------------------
# Deny-list extraction from the ADR's "### Deny-list" table.
# ---------------------------------------------------------------------------
# The table looks like:
#   ### Deny-list
#   ... prose ...
#   | Forbidden token | Where it would appear if reintroduced |
#   | --- | --- |
#   | `AuthMethodKubernetes` | Go SDK constant — must not exist |
#   | `case AuthMethodKubernetes` | Go switch dispatch — must not exist |
#   ...
#   ### Allow-list           ← next section terminates the table
#
# We extract every backtick-wrapped run in the FIRST `|`-delimited column.
# Rows whose first column is pure prose (no backticks at all) are silently
# skipped — see the header comment for why.
extract_deny_list() {
  if [ ! -f "$ADR_PATH" ]; then
    printf 'ADR file not found: %s\n' "$ADR_PATH" >&2
    exit 2
  fi
  # Only emit tokens from rows whose first column is *exclusively* one or
  # more backtick-wrapped strings separated by " / " (the ADR's convention
  # for grouping aliases — see `exchangeZitadelForVault / ZitadelToVault`).
  # Rows containing prose ("pointing at a Zitadel hostname", "payload with
  # bound_issuer pointing at...") describe structural patterns that need
  # human review, not literal-string rejection — they are skipped here.
  awk '
    BEGIN { in_section = 0 }
    /^### Deny-list/  { in_section = 1; next }
    /^### / && in_section { in_section = 0 }
    in_section && /^\|/ {
      if ($0 ~ /Forbidden token/) next
      if ($0 ~ /^\|[[:space:]]*-+[[:space:]]*\|/) next
      n = split($0, cols, "|")
      if (n < 2) next
      first = cols[2]
      # Trim leading/trailing whitespace.
      sub(/^[[:space:]]+/, "", first)
      sub(/[[:space:]]+$/, "", first)
      # Also tolerate trailing " / similar named function" boilerplate so the
      # exchangeZitadelForVault row qualifies.
      trimmed = first
      sub(/[[:space:]]*\/[[:space:]]*similar[[:space:]]+named[[:space:]]+function[[:space:]]*$/, "", trimmed)
      # The first column qualifies iff it consists ONLY of:
      #   `token` ([ / `token` ])*
      # i.e. backtick-wrapped strings joined by " / " with no other text.
      if (trimmed !~ /^`[^`]+`([[:space:]]*\/[[:space:]]*`[^`]+`)*$/) next
      s = first
      while (match(s, /`[^`]+`/)) {
        tok = substr(s, RSTART + 1, RLENGTH - 2)
        if (length(tok) > 0) print tok
        s = substr(s, RSTART + RLENGTH)
      }
    }
  ' "$ADR_PATH" | awk '!seen[$0]++'
}

# ---------------------------------------------------------------------------
# Scanner: grep every deny-list token across the calling repo's tree.
# ---------------------------------------------------------------------------
# Excludes:
#   .git/                  — repo metadata
#   .worktrees/            — local-only sibling worktree clones
#   vendor/                — Go vendored deps (third-party code)
#   node_modules/          — JS deps
#   **/testdata/**         — Go test fixtures (intentional landmines)
#   *.lock / pnpm-lock.yaml / *.sum  — package manifest hashes
#   adr/0009-jwt-spiffe-everywhere.md  — the ADR itself (source of truth)
#   .github/.vault-auth-deny-list-allowlist.json  — the allowlist file
#   .github/workflows/vault-auth-method-deny-list.yml  — the caller workflow
#   .github/workflows/adr-0009-deny-list.yml          — legacy alternate name
#
# The reusable workflow file in zero-day-ai/.github is on a different
# checkout (docs-repo/ is the docs sibling; the calling repo is at $REPO_ROOT)
# so it does not appear in the scan.
scan_repo() {
  local token_count=0
  local violation_count=0
  local clean_count=0
  : >"$VIOL_FILE"

  while IFS= read -r token; do
    [ -z "$token" ] && continue
    token_count=$((token_count + 1))
    # Use grep -F (fixed string) to avoid regex interpretation of the token.
    # -n prints line numbers; -I skips binary files; -r recurses.
    # The exclude-dir / exclude flags handle the noise paths.
    if grep -rn -F -I \
      --exclude-dir=.git \
      --exclude-dir=.worktrees \
      --exclude-dir=.claude \
      --exclude-dir=.spec-workflow \
      --exclude-dir=.scratch \
      --exclude-dir=vendor \
      --exclude-dir=node_modules \
      --exclude-dir=testdata \
      --exclude-dir=__snapshots__ \
      --exclude=pnpm-lock.yaml \
      --exclude=go.sum \
      --exclude=package-lock.json \
      --exclude=yarn.lock \
      --exclude='*.lock' \
      --exclude='0009-jwt-spiffe-everywhere.md' \
      --exclude='adr-0009-deny-list.md' \
      --exclude='.vault-auth-deny-list-allowlist.json' \
      --exclude='vault-auth-method-deny-list.yml' \
      --exclude='adr-0009-deny-list.yml' \
      --exclude='vault-auth-deny-list-scan.sh' \
      -- "$token" "$REPO_ROOT" 2>/dev/null \
      | awk -v t="$token" -F: '{
          # file = $1, line = $2, content = the rest
          rel = $1; sub(/^.*\/\.\//, "", rel)
          line = $2
          rest = ""
          for (i = 3; i <= NF; i++) rest = rest (i == 3 ? "" : ":") $i
          # Strip leading $REPO_ROOT/ from the path for stable display.
          printf "%s\t%s\t%s\t%s\n", rel, line, t, rest
        }' >>"$VIOL_FILE"
    then
      :
    else
      # grep exits 1 on no-match; that is the clean case for this token.
      clean_count=$((clean_count + 1))
    fi
  done < <(extract_deny_list)

  # Normalise paths: drop the $REPO_ROOT prefix.
  if [ -s "$VIOL_FILE" ]; then
    # Portable strip of the prefix.
    sed -i "s|^${REPO_ROOT}/||" "$VIOL_FILE" 2>/dev/null || true
  fi

  violation_count=$(wc -l <"$VIOL_FILE" | tr -d ' ')
  echo "[scan] deny-list tokens parsed: $token_count"
  echo "[scan] violation rows: $violation_count"
}

# ---------------------------------------------------------------------------
# Allowlist diff: compare scan results to the committed allowlist file.
# ---------------------------------------------------------------------------
# Allowlist entries that no longer match in source are stale and fail the
# run (monotonic-shrink). Violations not present in the allowlist fail the
# run (new regression).
diff_against_allowlist() {
  local allow_entries
  if [ -f "$ALLOWLIST" ]; then
    # Validate the JSON parses, then turn each entry into a "file\tline\ttoken" key.
    if ! command -v jq >/dev/null 2>&1; then
      echo "::error::jq is required to read the allowlist; it is preinstalled on ubuntu-latest GitHub runners"
      exit 2
    fi
    allow_entries=$(jq -r '.[] | [.file, (.line|tostring), .token] | @tsv' "$ALLOWLIST" 2>/dev/null || true)
  else
    allow_entries=""
  fi

  # Build sets of violations and allowlist entries keyed by file\tline\ttoken.
  : >"$STALE_FILE"
  : >"$FRESH_FILE"

  awk -F'\t' 'NF>=3 && $1!="" {print $1 "\t" $2 "\t" $3}' "$VIOL_FILE" | sort -u >"$SCAN_KEYS"
  # Filter blank lines so we don't count empty allowlists as having one entry.
  printf '%s\n' "$allow_entries" | awk 'NF>0' | sort -u >"$ALLOW_KEYS"

  # Fresh violations: in scan, not in allowlist
  comm -23 "$SCAN_KEYS" "$ALLOW_KEYS" >"$FRESH_FILE"
  # Stale allowlist entries: in allowlist, not in scan
  comm -13 "$SCAN_KEYS" "$ALLOW_KEYS" >"$STALE_FILE"

  local fresh_n
  local stale_n
  fresh_n=$(awk 'NF>0' "$FRESH_FILE" | wc -l | tr -d ' ')
  stale_n=$(awk 'NF>0' "$STALE_FILE" | wc -l | tr -d ' ')

  local rc=0

  if [ "$fresh_n" -gt 0 ] && [ -s "$FRESH_FILE" ]; then
    echo
    echo "::error::ADR-0009 deny-list violation — $fresh_n new occurrence(s) found."
    echo "Source of truth: $ADR_URL"
    echo "Allowlist file:  $ALLOWLIST"
    echo
    while IFS=$'\t' read -r f l t; do
      [ -z "$f" ] && continue
      # Find the matching line content from the full violation file for the
      # operator-friendly error message.
      content=$(awk -F'\t' -v f="$f" -v l="$l" -v t="$t" '$1==f && $2==l && $3==t {print $4; exit}' "$VIOL_FILE")
      echo "::error file=$f,line=$l::ADR-0009 deny-list violation: '$t' (line: $content)"
      echo "  $f:$l: $t"
      echo "    $content"
    done <"$FRESH_FILE"
    echo
    echo "Fix: remove the forbidden token. The ADR documents the canonical replacement pattern at $ADR_URL."
    echo "If the token is legitimate (rare — e.g. a documentation cross-reference), add an entry to $ALLOWLIST:"
    echo "  {\"file\": \"<path>\", \"line\": <line>, \"token\": \"<token>\", \"reason\": \"<one sentence>\"}"
    rc=1
  fi

  if [ "$stale_n" -gt 0 ] && [ -s "$STALE_FILE" ]; then
    echo
    echo "::error::ADR-0009 deny-list allowlist drift — $stale_n stale entries no longer match source."
    echo "Stale allowlist entries (remove from $ALLOWLIST):"
    while IFS=$'\t' read -r f l t; do
      [ -z "$f" ] && continue
      echo "  $f:$l: $t"
    done <"$STALE_FILE"
    echo
    echo "Monotonic-shrink: when a deny-list match is removed from source, its allowlist entry must be removed too."
    rc=1
  fi

  if [ "$rc" -eq 0 ]; then
    echo "[scan] clean — no ADR-0009 deny-list violations."
    if [ -f "$ALLOWLIST" ]; then
      local known
      known=$(jq -r 'length' "$ALLOWLIST" 2>/dev/null || echo 0)
      echo "[scan] $known known allowlisted exception(s) in $ALLOWLIST"
    fi
  fi

  return "$rc"
}

# ---------------------------------------------------------------------------
# Self-test: synthesise a temp file per deny-list token; assert each is caught.
# ---------------------------------------------------------------------------
selftest() {
  local tmp
  tmp="$SCAN_TMPDIR/selftest"
  mkdir -p "$tmp"

  local i=0
  local failed=0
  local total=0

  echo "[selftest] writing one synthetic file per deny-list token to $tmp/"
  while IFS= read -r token; do
    [ -z "$token" ] && continue
    i=$((i + 1))
    total=$((total + 1))
    # Embed the token in a file that looks like real source so the scanner
    # treats it as a normal scan target (no excluded path / no excluded ext).
    printf 'package fake\nfunc Use() { _ = "%s" }\n' "$token" >"$tmp/synthetic_${i}.go"
  done < <(extract_deny_list)

  if [ "$total" -eq 0 ]; then
    echo "::error::selftest could not parse any deny-list tokens from $ADR_PATH"
    return 2
  fi

  # Run the scanner against the synthetic tree and assert every token shows up
  # at least once in the violation file.
  REPO_ROOT="$tmp" ALLOWLIST="/dev/null" scan_repo

  while IFS= read -r token; do
    [ -z "$token" ] && continue
    if ! awk -F'\t' -v t="$token" '$3 == t { found = 1 } END { exit !found }' "$VIOL_FILE"; then
      echo "::error::selftest FAILED: scanner did not flag deny-list token '$token'"
      failed=$((failed + 1))
    fi
  done < <(extract_deny_list)

  if [ "$failed" -gt 0 ]; then
    echo "[selftest] $failed/$total tokens were NOT caught — scanner regex is broken."
    return 1
  fi
  echo "[selftest] all $total deny-list tokens caught."
  return 0
}

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------
SCAN_TMPDIR=$(mktemp -d)
VIOL_FILE="$SCAN_TMPDIR/violations.tsv"
FRESH_FILE="$SCAN_TMPDIR/fresh.tsv"
STALE_FILE="$SCAN_TMPDIR/stale.tsv"
SCAN_KEYS="$SCAN_TMPDIR/scan-keys.tsv"
ALLOW_KEYS="$SCAN_TMPDIR/allow-keys.tsv"
cleanup() { rm -rf "${SCAN_TMPDIR:-}"; }
trap cleanup EXIT

case "$MODE" in
  --selftest|selftest)
    selftest
    ;;
  scan|--scan|"")
    scan_repo
    diff_against_allowlist
    ;;
  --dump-violations|dump-violations)
    # Bootstrap-only helper: emit current violations as a JSON allowlist
    # to stdout. Useful for seeding .vault-auth-deny-list-allowlist.json.
    # CI never invokes this mode.
    scan_repo >/dev/null 2>&1
    awk -F'\t' '
      NF >= 3 && $1 != "" {
        # Escape quotes in the line content
        gsub(/\\/, "\\\\", $4)
        gsub(/"/, "\\\"", $4)
        entries[NR] = sprintf("  {\"file\": \"%s\", \"line\": %s, \"token\": \"%s\", \"reason\": \"pre-ADR-0009 cross-reference\"}", $1, $2, $3)
      }
      END {
        printf "[\n"
        for (i = 1; i <= NR; i++) {
          printf "%s%s\n", entries[i], (i < NR ? "," : "")
        }
        printf "]\n"
      }
    ' "$VIOL_FILE" | jq 'sort_by(.file, .line, .token) | unique_by([.file, .line, .token])'
    ;;
  *)
    echo "usage: $0 [scan|--selftest|--dump-violations]" >&2
    exit 2
    ;;
esac
