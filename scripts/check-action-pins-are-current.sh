#!/usr/bin/env bash
#
# check-action-pins-are-current.sh — a reusable workflow must not pin a
# first-party action to a SHA whose content is older than the latest release.
#
# THE FAILURE THIS CATCHES, which happened:
#
#   1. gate-image-vulns gained vendored-binaries support.   release v0.8.3
#   2. reusable-image-build.yml was re-pinned to v0.8.3.    release v0.9.0
#   3. gate-image-vulns' reachability extraction was FIXED. release v0.10.0
#   4. setec bumped to the reusable at v0.10.0 ... which still called the ACTION
#      at v0.8.3, so it ran the broken extraction and reported 350 reachable
#      advisory ids per binary — the size of the advisory database.
#
# Step 3 needs its own re-pin and nothing asked for one. A reusable pins its own
# actions by SHA on purpose (PR #88: `@main` is what made sha_pinning_required
# unflippable), and the cost of that is exactly this: every action change needs a
# follow-up re-pin, and forgetting it runs old code silently.
#
# THE COMPARISON IS AGAINST THE LATEST RELEASE TAG, not HEAD. Against HEAD the
# guard would be unsatisfiable: merging an action change makes every pin stale
# until a release exists to pin to. Against the latest tag it goes red exactly
# when the re-pin becomes possible — the release that carries the change — and
# stays green through the merge that introduced it.
#
# Usage:
#   check-action-pins-are-current.sh [--ref <tag-or-sha>]
#   check-action-pins-are-current.sh --selftest
set -euo pipefail
cd "$(dirname "$0")/.."

ref=""
selftest=0
fix=0
# WORKFLOWS_DIR lets the selftest point --fix at a scratch COPY of the workflow
# files while still running this script, from this working tree, against the real
# git history. The first fixture used `git worktree add HEAD` and so exercised the
# COMMITTED script, which did not have --fix yet and reported a usage error that
# read as a rewrite failure.
WORKFLOWS_DIR="${WORKFLOWS_DIR:-.github/workflows}"
while [ $# -gt 0 ]; do
  case "$1" in
    --ref) ref="$2"; shift 2 ;;
    --selftest) selftest=1; shift ;;
    --fix) fix=1; shift ;;
    *) echo "usage: $0 [--ref <tag>] [--fix] | --selftest" >&2; exit 2 ;;
  esac
done

# pins prints "file<TAB>action<TAB>sha" for every first-party action reference.
pins() {
  grep -rhoE 'zeroroot-ai/\.github/actions/[a-z0-9-]+@[0-9a-f]{40}' "$WORKFLOWS_DIR"/*.yml 2>/dev/null \
    | sort -u \
    | while IFS= read -r m; do
        a="${m#zeroroot-ai/.github/actions/}"; a="${a%@*}"
        printf '%s\t%s\n' "$a" "${m##*@}"
      done
}

# stale <action> <pinned-sha> <ref>: does the action's content differ between the
# pinned SHA and ref?
stale() {
  local action="$1" sha="$2" at="$3"
  ! git diff --quiet "$sha" "$at" -- "actions/${action}/" 2>/dev/null
}

check() {
  local at="$1" rc=0 checked=0 bad=0
  if ! git rev-parse --verify --quiet "$at" >/dev/null; then
    echo "❌ cannot resolve ${at}; fetch tags first (git fetch --tags)" >&2
    return 1
  fi
  while IFS=$'\t' read -r action sha; do
    [ -n "${action:-}" ] || continue
    if [ ! -d "actions/${action}" ]; then
      echo "❌ a workflow pins actions/${action}, which does not exist in this tree" >&2
      rc=1; continue
    fi
    checked=$((checked + 1))
    if stale "$action" "$sha" "$at"; then
      bad=$((bad + 1)); rc=1
      {
        printf '❌ actions/%s is pinned to %s, whose content differs from %s.\n' "$action" "${sha:0:12}" "$at"
        printf '   The reusable that pins it is running OLD action code. Re-pin it to %s:\n' "$at"
        printf '       %s  # %s\n' "$(git rev-parse "$at")" "$at"
        printf '   Changed files:\n'
        git diff --name-only "$sha" "$at" -- "actions/${action}/" | sed 's/^/     /'
      } >&2
    fi
  done < <(pins)

  # A FLOOR. This repo has several first-party actions; reading none of them is
  # how a guard reports success after measuring nothing.
  if [ "$checked" -lt 3 ]; then
    echo "❌ only ${checked} action pin(s) found; the extraction is not matching the workflows" >&2
    return 1
  fi
  if [ "$rc" -eq 0 ]; then
    echo "✅ ${checked} action pin(s) current with ${at}"
  fi
  return $rc
}

latest_tag() { git describe --tags --abbrev=0 2>/dev/null || git tag --sort=-v:refname | head -1; }

# fix_pins rewrites every stale first-party pin to ref, in place.
#
# It lives here rather than in a separate rewriter because the comparison and the
# rewrite must agree about what "stale" means. Two implementations of one rule is
# the shape that produced the bug this whole file exists for: a reusable pinning
# an action that a release had already moved past, three times in one day.
#
# It never commits and never pushes. The caller opens a pull request, because a
# push to main is not a thing this org does.
fix_pins() {
  local at="$1" newsha
  newsha="$(git rev-parse "$at")"
  # The rewrite is done in python, not sed. The replacement text contains a `#`
  # (the version comment), and every punctuation character that reads naturally as
  # a sed delimiter also appears in a pin line or a path. The first draft used `#`
  # and died with `unknown option to s`, which a fixture caught — a rewriter that
  # silently half-applies is worse than one that refuses.
  STALE="$(stale_list "$at")" NEWSHA="$newsha" AT="$at" WORKFLOWS_DIR="$WORKFLOWS_DIR" python3 - <<'PY_FIX'
import os, re, pathlib, sys

stale = [l.split('\t') for l in os.environ['STALE'].splitlines() if l.strip()]
newsha, at = os.environ['NEWSHA'], os.environ['AT']
if not stale:
    print('no stale pins; nothing to re-pin')
    sys.exit(0)

changed = 0
for path in sorted(pathlib.Path(os.environ.get('WORKFLOWS_DIR', '.github/workflows')).glob('*.yml')):
    text = original = path.read_text()
    for action, sha in stale:
        # Match the pin and whatever trailing version comment it carries, so the
        # SHA and the comment can never disagree afterwards.
        pat = re.compile(
            r'(zeroroot-ai/\.github/actions/' + re.escape(action) + r')@'
            + re.escape(sha) + r'(?:[ \t]*#[^\n]*)?')
        text, n = pat.subn(lambda m: '%s@%s # %s' % (m.group(1), newsha, at), text)
        if n:
            print('repinned %s: actions/%s %s -> %s  # %s'
                  % (path, action, sha[:12], newsha[:12], at))
    if text != original:
        path.write_text(text)
        changed += 1

if changed == 0:
    print('::error::%d stale pin(s) were reported and none could be rewritten; '
          'the pin line shape is not what this rewriter expects' % len(stale))
    sys.exit(1)
PY_FIX
}

# stale_list prints "action<TAB>sha" for the stale pins only. Shared by --fix so
# the rewrite and the check cannot disagree about which pins are stale.
stale_list() {
  local at="$1"
  while IFS=$'\t' read -r action sha; do
    [ -n "${action:-}" ] || continue
    [ -d "actions/${action}" ] || continue
    stale "$action" "$sha" "$at" && printf '%s\t%s\n' "$action" "$sha"
  done < <(pins)
}

selftest_run() {
  local pass=0 fail=0
  local at; at="$(latest_tag)"
  [ -n "$at" ] || { echo "SELFTEST FAIL: no tag to compare against"; return 1; }

  # 1. The extraction must find the real pins.
  local n; n=$(pins | wc -l | tr -d ' ')
  if [ "$n" -ge 3 ]; then pass=$((pass+1)); echo "selftest ok: found ${n} action pins"
  else fail=$((fail+1)); echo "SELFTEST FAIL: found only ${n} pins"; fi

  # 2. A pin to an ANCIENT sha must be reported stale. The first commit that
  #    touched any action predates every current pin by construction.
  #
  # NO `| head -1` ON pins HERE. Under `set -o pipefail` head exits after its
  # first line, pins takes SIGPIPE, and the whole selftest dies with 141 before
  # reaching case 2 — which it did, while still printing "selftest ok" for case 1.
  # Capture first, slice after.
  local all action old probe=""
  all="$(pins)"

  # Pick an action whose content ACTUALLY CHANGED between its first commit and
  # the ref. The first version of this took the first pin alphabetically, got
  # brand-guard, and brand-guard has never changed since it was created — so the
  # case failed for the fixture's reason rather than the guard's.
  while IFS=$'\t' read -r action _; do
    [ -n "${action:-}" ] || continue
    old="$(git log --format=%H -- "actions/${action}/" | tail -1)"
    if [ -n "$old" ] && stale "$action" "$old" "$at"; then probe="$action"; break; fi
  done < <(printf '%s\n' "$all")

  if [ -n "$probe" ]; then
    pass=$((pass+1)); echo "selftest ok: a pin to the first commit of actions/${probe} reads stale"
  else
    # Honest, not a pass: on a tree where no action has ever changed there is
    # nothing for this rule to detect, and saying so beats inventing a result.
    fail=$((fail+1))
    echo "SELFTEST FAIL: no action has changed since its first commit, so the stale rule could not be exercised"
  fi

  # 3. A pin AT the ref must not be stale.
  if stale "$action" "$(git rev-parse "$at")" "$at"; then
    fail=$((fail+1)); echo "SELFTEST FAIL: a pin at ${at} itself read stale"
  else
    pass=$((pass+1)); echo "selftest ok: a pin at ${at} is not stale"
  fi

  # --fix must actually rewrite. This case exists because the first rewriter used
  # sed with `#` as the delimiter while the replacement contains a `#` for the
  # version comment, and died with `unknown option to s`. A rewriter that
  # half-applies is worse than one that refuses, and only running it found that.
  #
  # It reuses $probe from case 2 rather than picking its own action, because this
  # file already records what happens otherwise: the first pin alphabetically is
  # brand-guard, whose content has never changed, so a regressed pin to it is not
  # stale and the case fails for the fixture's reason. I made that mistake again
  # here before reading three lines up.
  #
  # The rewrite runs against a scratch COPY of the workflow files via
  # WORKFLOWS_DIR, so the selftest never edits the tree it is checking, and it
  # invokes THIS working tree's script — an earlier version used
  # `git worktree add HEAD` and so tested the committed copy, which did not have
  # --fix at all and answered with a usage error that read as a rewrite failure.
  if [ -n "$probe" ]; then
    local scratch probe_old newsha
    scratch="$(mktemp -d)"
    cp "$WORKFLOWS_DIR"/*.yml "$scratch"/ 2>/dev/null || true
    probe_old="$(git log --format=%H -- "actions/${probe}/" | tail -1)"
    newsha="$(git rev-parse "$at")"
    sed -i -E "s|(actions/${probe})@[0-9a-f]{40}[^\n]*|\1@${probe_old} # stale|g" "$scratch"/*.yml
    WORKFLOWS_DIR="$scratch" bash "$0" --ref "$at" --fix >/dev/null 2>&1 || true
    if grep -qE "actions/${probe}@${newsha}" "$scratch"/*.yml 2>/dev/null; then
      pass=$((pass+1)); echo "selftest ok: --fix rewrote a stale pin for actions/${probe} to ${at}"
    else
      fail=$((fail+1)); echo "selftest FAIL: --fix did not rewrite a stale pin for actions/${probe}"
    fi
    # The version comment must move with the SHA. A pin whose comment disagrees
    # with it is worse than a stale pin: the comment is what a reader checks.
    if grep -qE "actions/${probe}@${newsha} # ${at}\b" "$scratch"/*.yml 2>/dev/null; then
      pass=$((pass+1)); echo "selftest ok: --fix moved the version comment to ${at}"
    else
      fail=$((fail+1)); echo "selftest FAIL: --fix left a version comment that disagrees with the SHA"
    fi
    rm -rf "$scratch"
  else
    echo "selftest skip: no action changed since its first commit, so --fix has nothing to rewrite"
  fi

  echo "selftest: ${pass} passed, ${fail} failed"
  [ "$fail" -eq 0 ] || return 1
  [ "$pass" -ge 3 ] || { echo "SELFTEST FAIL: only ${pass} case(s) ran"; return 1; }
  echo "✅ self-test: ${pass} cases, the guard can fail"
}

if [ "$selftest" = "1" ]; then selftest_run; exit $?; fi
if [ "$fix" = "1" ]; then fix_pins "${ref:-$(latest_tag)}"; exit $?; fi
check "${ref:-$(latest_tag)}"
