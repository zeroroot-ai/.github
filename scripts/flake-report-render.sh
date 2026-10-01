#!/usr/bin/env bash
# scripts/flake-report-render.sh — render the org flake report body.
#
# Reads the tree of flake-log artifacts that
# .github/workflows/flake-report.yml downloads (one JSON per scanned run,
# emitted by actions/flake-quarantine) and prints the issue body on stdout.
#
# `gh run download --pattern` nests each artifact in a directory named
# after it, so the layout is:
#
#   <dir>/<repo>-<run-id>/<artifact-name>/flake.json
#
# There are THREE states, not two (.github#249):
#
#   1. no artifacts at all      — nobody emitted a flake log in the window
#   2. artifacts, none flaked   — the pipeline is live and every wrapped
#                                 command passed on attempt 1; that is
#                                 signal worth stating, since it proves
#                                 adopters are wired
#   3. artifacts with flakes    — the table
#
# State 2 used to fall through to the table branch and render a bare
# markdown header with zero rows.
#
# Usage:
#   flake-report-render.sh <flakes-dir> [<window-days>] [<download-failures>]
#   flake-report-render.sh --count <flakes-dir>
#   flake-report-render.sh --selftest
#
# --count prints the number of runs that flaked, so the workflow can close a
# stale report instead of leaving it open asserting nothing actionable. The
# sarif-triage and makefile-contract audits already self-heal this way; this
# one did not, so .github#120 sat open saying "there is just nothing to
# report".
#
set -euo pipefail

WINDOW_DEFAULT=7

render() {
  local dir="$1"
  local window="${2:-$WINDOW_DEFAULT}"
  local download_failures="${3:-0}"

  local logs=()
  if [ -d "$dir" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && logs+=("$f")
    done < <(find "$dir" -type f -name '*.json' | sort)
  fi

  printf '## Weekly flake report — %s\n\n' "$(date -u +%Y-%m-%d)"

  if [ "${#logs[@]}" -eq 0 ]; then
    printf 'No flake events found in the last %s days: no run in the scanned repos retried under actions/flake-quarantine this week.\n' "$window"
    render_download_warning "$download_failures"
    return 0
  fi

  # Collect the flaky rows first: the table header is only worth printing
  # if at least one row follows it.
  local rows=""
  local flaked=0
  local f repo run cmd is_flake failed
  for f in "${logs[@]}"; do
    is_flake=$(jq -r '.is_flake // false' "$f")
    [ "$is_flake" = "true" ] || continue
    repo=$(jq -r '.repo | sub("^zeroroot-ai/"; "")' "$f")
    run=$(basename "$(dirname "$(dirname "$f")")" | sed "s/^$repo-//")
    cmd=$(jq -r '.cmd // "unknown"' "$f")
    failed=$(jq -r '.failed_attempts | length' "$f")
    rows="${rows}| ${repo} | \`${cmd}\` | ${run} | ${failed} |"$'\n'
    flaked=$((flaked + 1))
  done

  if [ "$flaked" -eq 0 ]; then
    printf '%s quarantined run(s) collected in the last %s days, none flaked — every wrapped command passed on attempt 1.\n\n' \
      "${#logs[@]}" "$window"
    printf 'The quarantine pipeline is live: adopters are emitting flake logs, there is just nothing to report.\n'
    render_download_warning "$download_failures"
    return 0
  fi

  printf '%s of %s quarantined run(s) collected in the last %s days flaked.\n\n' \
    "$flaked" "${#logs[@]}" "$window"
  printf '| Repo | Test command | Run | Failed attempts |\n'
  printf '|---|---|---|---|\n'
  printf '%s' "$rows"
  render_download_warning "$download_failures"
}

# flaked_count prints how many collected runs actually flaked. States 1 and 2
# of render() both yield 0.
flaked_count() {
  local dir="$1" f n=0
  [ -d "$dir" ] || { printf '0'; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ "$(jq -r '.is_flake // false' "$f")" = "true" ] && n=$((n + 1))
  done < <(find "$dir" -type f -name '*.json' | sort)
  printf '%s' "$n"
}

render_download_warning() {
  local failures="$1"
  [ "$failures" -gt 0 ] 2>/dev/null || return 0
  printf '\n⚠ %s artifact download(s) failed this run — the report above may be incomplete (see the workflow log).\n' "$failures"
}

write_log() {
  local dir="$1" repo="$2" run="$3" is_flake="$4" cmd="$5" failed="$6"
  mkdir -p "$dir/$repo-$run/flake-log-$run"
  jq -n --arg r "zeroroot-ai/$repo" --argjson f "$is_flake" --arg c "$cmd" --argjson n "$failed" \
    '{repo: $r, is_flake: $f, cmd: $c, failed_attempts: [range($n) | "attempt"]}' \
    >"$dir/$repo-$run/flake-log-$run/flake.json"
}

# selftest exercises all three states and asserts the distinguishing
# property of each, so the empty-table regression cannot come back
# unnoticed.
selftest() {
  local tmp
  tmp=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  local out failures=0

  # --- state 1: no artifacts at all
  mkdir -p "$tmp/empty"
  out=$(render "$tmp/empty")
  if grep -q '^|' <<<"$out"; then
    echo "::error::[selftest] state 1 (no artifacts) rendered a table"
    failures=$((failures + 1))
  fi
  if ! grep -q 'No flake events found' <<<"$out"; then
    echo "::error::[selftest] state 1 (no artifacts) lost its explanation"
    failures=$((failures + 1))
  fi

  # --- state 2: artifacts collected, none flaked  (.github#249)
  write_log "$tmp/clean" "setec" "31721834768" false "make test" 0
  write_log "$tmp/clean" "docs-site" "31721834799" false "pnpm test" 0
  out=$(render "$tmp/clean")
  if grep -q '^|' <<<"$out"; then
    echo "::error::[selftest] state 2 (none flaked) rendered a table header with no rows"
    failures=$((failures + 1))
  fi
  if ! grep -q '2 quarantined run(s) collected' <<<"$out"; then
    echo "::error::[selftest] state 2 (none flaked) did not report the collected count"
    failures=$((failures + 1))
  fi

  # --- state 3: at least one flake. `docs-site` is deliberate: the run id
  # must survive a repo name that itself contains a dash.
  write_log "$tmp/flaky" "setec" "31721834768" false "make test" 0
  write_log "$tmp/flaky" "docs-site" "31721834900" true "pnpm test" 2
  out=$(render "$tmp/flaky")
  if ! grep -q '^| Repo | Test command | Run | Failed attempts |$' <<<"$out"; then
    echo "::error::[selftest] state 3 (flakes) lost the table header"
    failures=$((failures + 1))
  fi
  # shellcheck disable=SC2016  # the backticks are literal markdown in the row
  if ! grep -q '^| docs-site | `pnpm test` | 31721834900 | 2 |$' <<<"$out"; then
    echo "::error::[selftest] state 3 (flakes) lost the flaky row, or mangled a dashed repo name"
    echo "$out"
    failures=$((failures + 1))
  fi
  if grep -q 'setec' <<<"$out"; then
    echo "::error::[selftest] state 3 (flakes) listed a run that did not flake"
    failures=$((failures + 1))
  fi

  # --- the incomplete-download warning survives every state
  out=$(render "$tmp/clean" 7 3)
  if ! grep -q '3 artifact download(s) failed' <<<"$out"; then
    echo "::error::[selftest] the download-failure warning was dropped"
    failures=$((failures + 1))
  fi

  # --- --count agrees with what each state rendered. This is what decides
  # whether the workflow closes the report, so it is asserted, not assumed.
  if [ "$(flaked_count "$tmp/empty")" != "0" ]; then
    echo "::error::[selftest] --count on state 1 (no artifacts) is not 0"
    failures=$((failures + 1))
  fi
  if [ "$(flaked_count "$tmp/clean")" != "0" ]; then
    echo "::error::[selftest] --count on state 2 (none flaked) is not 0"
    failures=$((failures + 1))
  fi
  if [ "$(flaked_count "$tmp/flaky")" != "1" ]; then
    echo "::error::[selftest] --count on state 3 (one flake of two runs) is not 1"
    failures=$((failures + 1))
  fi
  if [ "$(flaked_count "$tmp/does-not-exist")" != "0" ]; then
    echo "::error::[selftest] --count on a missing directory is not 0"
    failures=$((failures + 1))
  fi

  if [ "$failures" -ne 0 ]; then
    echo "[selftest] $failures assertion(s) failed"
    return 1
  fi

  echo "[selftest] all three render states behave, and --count agrees with each"
}

main() {
  case "${1:-}" in
    --selftest)
      selftest
      ;;
    --count)
      [ $# -ge 2 ] || { echo "usage: $0 --count <flakes-dir>" >&2; exit 2; }
      flaked_count "$2"
      ;;
    "" | -h | --help)
      echo "usage: $0 <flakes-dir> [<window-days>] [<download-failures>] | $0 --count <flakes-dir> | $0 --selftest" >&2
      exit 2
      ;;
    *)
      render "$@"
      ;;
  esac
}

main "$@"
