#!/usr/bin/env bash
# Assertions for the runs-on-lint classifier.
#
# The classifier is INLINE in .github/workflows/runs-on-lint.yml — it has to be,
# because a reusable workflow checks out the CALLER, so scripts/ from this repo
# are not on disk when it runs (see that file's comment for the two failed
# attempts to work around it). Inline means the logic travels with the caller's
# pinned sha, which is the property that matters.
#
# So this test EXTRACTS the shipped case block between the BEGIN-CLASSIFIER and
# END-CLASSIFIER markers and runs the assertions against it. The tested thing
# and the shipped thing are therefore the same bytes; a reimplementation here
# would prove nothing.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="$here/../.github/workflows/runs-on-lint.yml"
fails=0

block="$(awk '/BEGIN-CLASSIFIER/{f=1;next} /END-CLASSIFIER/{f=0} f' "$wf")"
[ -n "$block" ] || { echo "FAIL: could not extract the classifier from $wf — markers missing or renamed"; exit 1; }
# Reach floor: the extracted block must actually be a case statement, not
# whitespace that silently passes every assertion.
echo "$block" | grep -q 'case "\$probe" in' || { echo "FAIL: extracted block is not the classifier"; exit 1; }
echo "$block" | grep -q 'ubuntu-\*' || { echo "FAIL: extracted block lacks the ubuntu arm"; exit 1; }

classify() {
  local probe
  probe="$(echo "$1" | sed -E 's/\$\{\{[^}]*\}\}/X/g')"
  eval "$block"
}

expect() { # expect <allow|reject> <label>
  local want="$1" label="$2" got
  if classify "$label"; then got=allow; else got=reject; fi
  if [ "$got" != "$want" ]; then
    echo "FAIL  want=$want got=$got  label='$label'"; fails=$((fails+1))
  else
    echo "ok    $want  '$label'"
  fi
}

echo "== sanctioned =="
expect allow  'ubuntu-latest'
expect allow  'ubuntu-24.04'
expect allow  'staging-ephemeral'
expect allow  'prod-ephemeral'
expect allow  '${{ inputs.env }}-ephemeral'
expect allow  '${{ matrix.env }}-ephemeral'

echo "== forbidden =="
# The three persistent runners ADR-0060 removed must never come back.
expect reject 'self-hosted'
expect reject 'workstation-setec-kvm'
expect reject 'ec2-kind-standup'
# A bare expression is unbounded — the guard cannot vouch for what it becomes.
expect reject '${{ inputs.runner }}'
expect reject '${{ inputs.env }}'
# The suffix must be a whole trailing token, not a substring.
expect reject 'ephemeral'
expect reject 'not-ephemeral-really'
# Other hosted platforms are out of scope by policy, not by oversight.
expect reject 'macos-14'
expect reject 'windows-latest'

echo "== no GitHub expression survives inside the run: block =="
# Actions interpolates the two-brace expression syntax even inside a SHELL
# COMMENT in a `run:` block. Leaving one there does not fail the step — it
# invalidates the whole workflow file, and every caller gets
# "This run likely failed because of a workflow file issue" with no log to
# read. Cost us a full round-trip on zeroroot-ai/gitops#544.
runblock="$(awk '/- name: Reject non-sanctioned/,0' "$wf")"
if printf '%s' "$runblock" | grep -q '\${{'; then
  echo "FAIL  a literal GitHub expression appears inside the run: block:"
  printf '%s' "$runblock" | grep -n '\${{' | sed 's/^/      /'
  fails=$((fails+1))
else
  echo "ok    run: block contains no interpolatable expression"
fi

if [ "$fails" -gt 0 ]; then echo; echo "$fails assertion(s) failed"; exit 1; fi
echo; echo "all assertions passed against the SHIPPED classifier"
