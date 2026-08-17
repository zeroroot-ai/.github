#!/usr/bin/env bash
#
# test-launch-scorecard.sh — the renderer must produce the RIGHT ORDER when the
# numbers are bad. A scorecard that cannot go red is worse than no scorecard,
# so every threshold here has a fixture that trips it.
#
# No network. Feeds crafted JSON to `launch-scorecard.sh render`.

set -euo pipefail
cd "$(dirname "$0")/.."

SCRIPT=scripts/launch-scorecard.sh
PASS=0 FAIL=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

assert_has()  { if grep -qF -- "$2" "$1"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: expected to find: $2"; fi; }
assert_lacks() { if grep -qF -- "$2" "$1"; then FAIL=$((FAIL+1)); echo "  FAIL: did not expect: $2"; else PASS=$((PASS+1)); fi; }

chain() { # n name status
  jq -n --argjson n "$1" --arg name "$2" --arg st "$3" \
    '{n:$n,name:$name,repo:"deploy",workflow:"w.yml",root:"deploy#1",
      exit_test:"t",status:$st,last_run:"2026-08-17T00:00:00Z",url:""}'
}

mkfixture() { # green_chain_count filed hygiene merged rework alerts openprs
  jq -n \
    --argjson chains "$(jq -s . <<<"$(chain 1 One "$1"; chain 2 Two NOT_BUILT)")" \
    --argjson filed "$2" --argjson hygiene "$3" --argjson merged "$4" \
    --argjson rework "$5" --argjson alerts "$6" --argjson openprs "$7" \
    '{generated_at:"2026-08-17T06:00:00Z", window_since:"2026-08-10", window_days:7,
      chains:$chains, chains_green:(if $chains[0].status=="PASS" then 1 else 0 end),
      chains_total:2,
      process:{issues_filed:$filed, issues_closed:0, prs_merged:$merged,
               hygiene_prs:$hygiene, rework_prs:$rework, alert_issues_open:$alerts,
               open_prs:$openprs}}'
}

echo "== everything bad: the 2026-08-13..17 shape =="
mkfixture FAIL 800 40 100 20 193 '{"deploy":7}' > "$tmp/bad.json"
cat > "$tmp/prev.md" <<'EOF'
<!--history-->
- 2026-08-16 green=0 filed=700 merged=90 hygiene=30%
- 2026-08-15 green=0 filed=600 merged=80 hygiene=30%
- 2026-08-14 green=0 filed=500 merged=70 hygiene=30%
<!--/history-->
EOF
PREV_BODY="$tmp/prev.md" "$SCRIPT" render < "$tmp/bad.json" > "$tmp/bad.md"

assert_has  "$tmp/bad.md" "STALLED"
assert_has  "$tmp/bad.md" "days with no chain flip. HALT."
assert_has  "$tmp/bad.md" "Work chain 1 (One) only."
assert_has  "$tmp/bad.md" "have no exit-test workflow"
assert_has  "$tmp/bad.md" "File nothing this session"
assert_has  "$tmp/bad.md" "tracker is being used as an alert queue"
assert_has  "$tmp/bad.md" "Hygiene work is 40% of merged PRs"
assert_has  "$tmp/bad.md" "Rework is 20% of merged PRs"
assert_has  "$tmp/bad.md" "has 7 open PRs"
assert_lacks "$tmp/bad.md" "No rule is breached"
# The history must carry forward, not reset.
assert_has  "$tmp/bad.md" "- 2026-08-14 green=0"

echo "== everything good =="
mkfixture PASS 4 1 40 0 0 '{"deploy":1}' > "$tmp/ok.json"
# Force chain 2 to PASS too so the board is fully green.
jq '.chains[1].status="PASS" | .chains_green=2' "$tmp/ok.json" > "$tmp/ok2.json"
"$SCRIPT" render < "$tmp/ok2.json" > "$tmp/ok.md"

assert_has   "$tmp/ok.md" "GREEN"
assert_has   "$tmp/ok.md" "No rule is breached"
assert_lacks "$tmp/ok.md" "HALT"
assert_lacks "$tmp/ok.md" "File nothing this session"

echo "== a first green chain clears the stall =="
# Same history as the bad case, but one chain flipped: stall must NOT fire.
jq '.chains[0].status="PASS" | .chains_green=1' "$tmp/bad.json" > "$tmp/flip.json"
PREV_BODY="$tmp/prev.md" "$SCRIPT" render < "$tmp/flip.json" > "$tmp/flip.md"
assert_lacks "$tmp/flip.md" "HALT"
assert_has   "$tmp/flip.md" "Work chain 2 (Two) only."

echo "== re-runs on one day are one history line, and do not count as a stall =="
# The workflow runs on a schedule, on dispatch, and on re-run. Counting those as
# elapsed days would order a false HALT on day one.
cat > "$tmp/prev-dupes.md" <<'EOF'
<!--history-->
- 2026-08-17 green=0 filed=581 merged=594 hygiene=40%
- 2026-08-17 green=0 filed=580 merged=593 hygiene=40%
- 2026-08-16 green=0 filed=500 merged=500 hygiene=40%
<!--/history-->
EOF
PREV_BODY="$tmp/prev-dupes.md" "$SCRIPT" render < "$tmp/bad.json" > "$tmp/dupes.md"
# One prior DAY at green=0 (2026-08-16) is a stall of 1, under the limit of 2.
assert_lacks "$tmp/dupes.md" "HALT"
# Today appears exactly once, carrying the newest numbers.
hist_today=$(sed -n '/<!--history-->/,/<!--\/history-->/p' "$tmp/dupes.md" | grep -c '^- 2026-08-17 ')
if [ "$hist_today" -eq 1 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: today appears $hist_today times in history, expected 1"; fi
assert_has "$tmp/dupes.md" "- 2026-08-16 green=0"

echo "== alert-farm threshold is a boundary, and the per-repo trackers are not counted =="
# collect() subtracts the one sanctioned "code-scanning digest" tracker per repo
# before this number is written, so 11 legitimate trackers must arrive here as 0.
mkfixture PASS 4 1 40 0 0 '{"deploy":1}' > "$tmp/a0.json"
"$SCRIPT" render < "$tmp/a0.json" > "$tmp/a0.md"
assert_lacks "$tmp/a0.md" "alert queue"

jq '.process.alert_issues_open=5' "$tmp/a0.json" > "$tmp/a5.json"
"$SCRIPT" render < "$tmp/a5.json" > "$tmp/a5.md"
assert_lacks "$tmp/a5.md" "alert queue"

jq '.process.alert_issues_open=6' "$tmp/a0.json" > "$tmp/a6.json"
"$SCRIPT" render < "$tmp/a6.json" > "$tmp/a6.md"
assert_has "$tmp/a6.md" "alert queue"
assert_has "$tmp/a6.md" "beyond the one standing tracker per repo"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
