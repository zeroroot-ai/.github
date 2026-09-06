#!/usr/bin/env bash
# Fixture + mutation tests for scripts/sarif-triage.sh.
#
# Proves the guards can actually fire (this org has a documented history of
# guards that cannot fail — every skip/abort path below is exercised with a
# fixture that must trigger it):
#
#   (1) A 404 "no analysis" API response files NOTHING (the .github#252
#       incident class: repos without code scanning got `rule null` issues).
#   (2) A hard API error files NOTHING and turns the run red.
#   (3) An exit-0 response whose body is an error OBJECT (not an array)
#       files NOTHING and turns the run red — never parsed as alerts.
#   (4) A real-shaped EMPTY array ([] = zero open alerts) files NOTHING.
#   (5) A real-shaped alert array files EXACTLY ONE digest issue; the body
#       lists error-severity rules in detail, rolls warning/note up into
#       counts, and links the repo's code-scanning UI.
#   (6) When a digest issue already exists, it is updated in place (edit,
#       not create).
#   (7) HARD SAFETY: a second NEW issue for the same repo in one run aborts
#       the whole run.
#   (8) Size caps: the rule table truncates at MAX_RULE_ROWS, and an
#       oversized body collapses to the counts+link summary.
#
# Called by the fixture-self-test job in .github/workflows/sarif-triage.yml,
# which gates the triage job on every run.

set -uo pipefail

cd "$(dirname "$0")/.."

# Sourcing brings in `set -e`; drop it — the tests manage exit codes.
# shellcheck source=scripts/sarif-triage.sh
source scripts/sarif-triage.sh
set +e

PASS=0
FAIL=0

ok()   { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# --------------------------------------------------------------------------
# gh mock. Behavior is driven by MOCK_* variables; every invocation is
# appended to $GH_CALLS_LOG, and any filed body is copied to $MOCK_BODY_OUT.
MOCK_API_STDOUT=""
MOCK_API_STDERR=""
MOCK_API_RC=0
MOCK_EXISTING_ISSUE=""
GH_CALLS_LOG=""
MOCK_BODY_OUT=""

gh() {
  echo "$*" >> "$GH_CALLS_LOG"
  case "$1 ${2:-}" in
    "api "*)
      printf '%s' "$MOCK_API_STDOUT"
      [ -n "$MOCK_API_STDERR" ] && printf '%s\n' "$MOCK_API_STDERR" >&2
      return "$MOCK_API_RC"
      ;;
    "issue list")
      printf '%s' "$MOCK_EXISTING_ISSUE"
      return 0
      ;;
    "issue create"|"issue edit")
      # capture --body-file contents
      local prev=""
      for arg in "$@"; do
        if [ "$prev" = "--body-file" ]; then cp "$arg" "$MOCK_BODY_OUT"; fi
        prev="$arg"
      done
      [ "$2" = "create" ] && echo "https://github.com/mock/issue/1"
      return 0
      ;;
    *)
      echo "unexpected gh invocation in test: $*" >&2
      return 1
      ;;
  esac
}

fresh() {
  GH_CALLS_LOG=$(mktemp)
  MOCK_BODY_OUT=$(mktemp)
  MOCK_API_STDOUT=""
  MOCK_API_STDERR=""
  MOCK_API_RC=0
  MOCK_EXISTING_ISSUE=""
  unset CREATED_PER_REPO
  declare -gA CREATED_PER_REPO
}

filed_count() { grep -c "^issue create\|^issue edit" "$GH_CALLS_LOG"; }
create_count() { grep -c "^issue create" "$GH_CALLS_LOG"; }
edit_count() { grep -c "^issue edit" "$GH_CALLS_LOG"; }

# A real-shaped code-scanning alerts page: 3 error alerts on 2 rules,
# 2 warnings on one rule, 1 note.
REAL_FIXTURE='[
  {"number": 11, "state": "open",
   "rule": {"id": "go/sql-injection", "severity": "error", "security_severity_level": "high"},
   "most_recent_instance": {"location": {"path": "internal/db/query.go", "start_line": 10}}},
  {"number": 12, "state": "open",
   "rule": {"id": "go/sql-injection", "severity": "error", "security_severity_level": "high"},
   "most_recent_instance": {"location": {"path": "internal/db/exec.go", "start_line": 44}}},
  {"number": 13, "state": "open",
   "rule": {"id": "go/path-injection", "severity": "error", "security_severity_level": "high"},
   "most_recent_instance": {"location": {"path": "cmd/server/main.go", "start_line": 7}}},
  {"number": 14, "state": "open",
   "rule": {"id": "go/unused-parameter-warnrule", "severity": "warning", "security_severity_level": null},
   "most_recent_instance": {"location": {"path": "pkg/util/x.go", "start_line": 1}}},
  {"number": 15, "state": "open",
   "rule": {"id": "go/unused-parameter-warnrule", "severity": "warning", "security_severity_level": null},
   "most_recent_instance": {"location": {"path": "pkg/util/y.go", "start_line": 2}}},
  {"number": 16, "state": "open",
   "rule": {"id": "go/todo-comment", "severity": "note", "security_severity_level": null},
   "most_recent_instance": {"location": {"path": "pkg/util/z.go", "start_line": 3}}}
]'

# --------------------------------------------------------------------------
# (1) 404 / no code scanning => skip, file nothing, run stays green
fresh
MOCK_API_RC=1
MOCK_API_STDERR="gh: no analysis found (HTTP 404)"
process_repo "norepo-scanning" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(filed_count)" -eq 0 ]; then
  ok "404/no-analysis response files nothing and is not an error"
else
  bad "404/no-analysis: rc=$rc filed=$(filed_count) (want rc=0 filed=0)"
fi

# (2) hard API error => file nothing, run turns red
fresh
MOCK_API_RC=1
MOCK_API_STDERR="gh: Internal Server Error (HTTP 500)"
process_repo "brokenapi" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ "$(filed_count)" -eq 0 ]; then
  ok "hard API error files nothing and turns the run red"
else
  bad "hard API error: rc=$rc filed=$(filed_count) (want rc!=0 filed=0)"
fi

# (3) exit-0 error OBJECT body (the incident class) => never parsed as alerts
fresh
MOCK_API_RC=0
MOCK_API_STDOUT='{"message": "no analysis found", "documentation_url": "https://docs.github.com"}'
process_repo "nullalerts" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ "$(filed_count)" -eq 0 ]; then
  ok "non-array (error object) response files nothing — no 'rule null' issue possible"
else
  bad "error-object response: rc=$rc filed=$(filed_count) (want rc!=0 filed=0)"
fi

# (4) empty array = zero open alerts => skip, file nothing, green
fresh
MOCK_API_STDOUT='[]'
process_repo "cleanrepo" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(filed_count)" -eq 0 ]; then
  ok "zero open alerts ([]) files nothing"
else
  bad "empty array: rc=$rc filed=$(filed_count) (want rc=0 filed=0)"
fi

# (5) real-shaped response => exactly ONE digest issue, body contract holds
fresh
MOCK_API_STDOUT="$REAL_FIXTURE"
process_repo "realrepo" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(create_count)" -eq 1 ] && [ "$(edit_count)" -eq 0 ]; then
  ok "real-shaped response files exactly one NEW digest issue"
else
  bad "real-shaped: rc=$rc creates=$(create_count) edits=$(edit_count) (want 1 create, 0 edits)"
fi
body=$(cat "$MOCK_BODY_OUT")
case "$body" in
  *'go/sql-injection'*) ok "digest lists error-severity rules in detail" ;;
  *) bad "digest body is missing the error rule table" ;;
esac
case "$body" in
  *'go/unused-parameter-warnrule'*) bad "digest lists a warning rule individually (severity floor broken)" ;;
  *) ok "warning/note rules roll up to counts only" ;;
esac
case "$body" in
  *'**6** total — 3 error, 2 warning, 1 note/other'*) ok "digest counts line is correct" ;;
  *) bad "digest counts line wrong or missing" ;;
esac
case "$body" in
  *'security/code-scanning?query=is%3Aopen'*) ok "digest links the repo code-scanning UI" ;;
  *) bad "digest is missing the code-scanning UI link" ;;
esac

# (6) existing digest issue => update in place (edit, not create)
fresh
MOCK_API_STDOUT="$REAL_FIXTURE"
MOCK_EXISTING_ISSUE="42"
process_repo "realrepo" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ "$(create_count)" -eq 0 ] && [ "$(edit_count)" -eq 1 ]; then
  ok "existing digest issue is updated in place"
else
  bad "update-in-place: rc=$rc creates=$(create_count) edits=$(edit_count) (want 0 creates, 1 edit)"
fi

# (7) HARD SAFETY: a second NEW issue for one repo aborts the whole run
fresh
bodyf=$(mktemp); echo "body" > "$bodyf"
(
  file_digest "dup-repo" 5 "$bodyf" >/dev/null 2>&1 &&
  file_digest "dup-repo" 5 "$bodyf" >/dev/null 2>&1
)
rc=$?
if [ "$rc" -ne 0 ] && [ "$(create_count)" -eq 1 ]; then
  ok "second NEW issue for the same repo aborts the run (created exactly 1)"
else
  bad "hard safety: rc=$rc creates=$(create_count) (want rc!=0, exactly 1 create)"
fi
rm -f "$bodyf"

# (8a) rule-row cap: >MAX_RULE_ROWS error rules truncate with a count + link
fresh
many=$(jq -n '[range(0; 40) | {number: ., state: "open",
  rule: {id: ("go/rule-\(.)"), severity: "error", security_severity_level: "high"},
  most_recent_instance: {location: {path: "pkg/f\(.).go", start_line: 1}}}]')
MOCK_API_STDOUT="$many"
process_repo "bigrepo" >/dev/null 2>&1
body=$(cat "$MOCK_BODY_OUT")
rowcount=$(printf '%s\n' "$body" | grep -c '^| `go/rule-')
case "$body" in
  *'more error-severity rules'*) truncated=1 ;;
  *) truncated=0 ;;
esac
if [ "$rowcount" -le "$MAX_RULE_ROWS" ] && [ "$truncated" -eq 1 ]; then
  ok "rule table truncates at MAX_RULE_ROWS with a remainder count"
else
  bad "row cap: rows=$rowcount truncated=$truncated (want <=$MAX_RULE_ROWS and a remainder line)"
fi

# (8b) byte cap: an oversized body collapses to the counts+link summary
fresh
MOCK_API_STDOUT="$REAL_FIXTURE"
(
  MAX_BODY_BYTES=200
  process_repo "tinycap" >/dev/null 2>&1
)
body=$(cat "$MOCK_BODY_OUT")
case "$body" in
  *'exceeded the digest size cap'*) ok "oversized body collapses to counts + link summary" ;;
  *) bad "byte cap did not collapse the body" ;;
esac
case "$body" in
  *'security/code-scanning?query=is%3Aopen'*) ok "summary form still links the code-scanning UI" ;;
  *) bad "summary form lost the code-scanning UI link" ;;
esac

# --------------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
