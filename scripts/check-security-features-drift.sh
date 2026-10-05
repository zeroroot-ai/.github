#!/usr/bin/env bash
# check-security-features-drift.sh — ADR-0088 is a repo SETTING, not a file, so
# nothing in git shows when it is turned off. This guard is the thing that shows.
#
# ADR-0088: every repo gets every security feature that APPLIES to it, and
# visibility is not an input to that decision. Three tiers:
#
#   1. secret scanning + push protection — EVERY repo, no exceptions. A
#      credential is a credential in a CSS repo and in an empty repo.
#   2. code scanning — every repo whose first-party code is in a language
#      CodeQL supports.
#   3. dependabot — every repo with a dependency graph.
#
# All three tiers are enforced here:
#
#   Tier 1 needs no judgment. It is universal, so there is nothing to decide and
#   nothing to exempt, which is what makes it enforceable without a config file
#   that would itself drift.
#
#   Tier 2 is decided from the repo's own primary language, which GitHub
#   reports. A private repo reports it in code_security. A public repo returns
#   `null` there, because CodeQL is configured by a workflow or by default
#   setup, so for a public repo the guard reads those two instead: a CodeQL
#   workflow on the default branch, or default setup in state `configured`.
#   This tier was skipped on public repos, which is most of them (.github#193).
#
#   Tier 3 is decided from the tree of the default branch. A repo has a
#   dependency manifest when the tree holds a file Dependabot reads: go.mod,
#   package.json, requirements.txt, pyproject.toml, Cargo.toml, Gemfile,
#   pom.xml, a Dockerfile, or a workflow under .github/workflows. The list is
#   MANIFEST_RE below, in one place. A repo with none of them has nothing for
#   Dependabot to update and is not checked.
#
#   A value the guard could not read is drift, never a pass.
#
# The live fetch is injected through SECURITY_FETCH_CMD so the mutation test can
# run in the pull_request lane, where an org token is not available.
#
# Usage: scripts/check-security-features-drift.sh
# Exit 0 = every repo matches ADR-0088. Exit 1 = at least one drifted.
set -uo pipefail

ORG="${ORG:-zeroroot-ai}"

# Languages CodeQL supports. A repo outside this set is not exempt because it is
# unimportant; the analysis simply cannot run on it.
CODEQL_LANGS="Go TypeScript JavaScript Python Ruby Java C# C++ C Kotlin Swift"

# A file that Dependabot reads. One list, matched against each path of the
# default branch tree.
MANIFEST_RE='(^|/)(go\.mod|package\.json|requirements\.txt|pyproject\.toml|Cargo\.toml|Gemfile|pom\.xml|Dockerfile[^/]*)$|^\.github/workflows/[^/]+\.ya?ml$'
CODEQL_WORKFLOW_RE='^\.github/workflows/[^/]*codeql[^/]*\.ya?ml$'

fetch() {
  if [ -n "${SECURITY_FETCH_CMD:-}" ]; then
    eval "$SECURITY_FETCH_CMD"
    return
  fi
  # REST, not GraphQL, and deliberately.
  #
  # The org-wide GraphQL enumeration this used to run is expensive, and the
  # GraphQL budget is a USER-level limit shared by every token that user holds
  # — so one agent exhausting it blocks everyone. This guard runs hourly and
  # after every repo recreation, so it is exactly the kind of recurring cost
  # that should not sit on a contended budget.
  #
  # /orgs/{org}/repos returns name, private, archived and language, which is
  # everything the GraphQL query selected. The per-repo call below was already
  # REST, so this leaves the guard on one API surface.
  gh api "/orgs/${ORG}/repos?per_page=100&type=all" --paginate \
    --jq '.[] | select(.archived | not)
          | [.name, (if .private then "private" else "public" end), (.language // "-"), .default_branch]
          | @tsv' \
  | while IFS=$'\t' read -r name vis lang branch; do
      sa=$(gh api "repos/${ORG}/${name}" --jq '.security_and_analysis' 2>/dev/null)
      g() { printf '%s' "$sa" | jq -r ".$1.status // \"absent\"" 2>/dev/null; }

      # The tree of the default branch: how many dependency manifests, and
      # whether a CodeQL workflow is among the workflows.
      local tree manifests dependabot codescan
      # A truncated listing is not the tree. GitHub cuts a recursive listing
      # at 100,000 entries and says so; a guard that read the cut list would
      # miss a manifest and report a clean repo.
      if tree=$(gh api "repos/${ORG}/${name}/git/trees/${branch}?recursive=1" \
                  --jq 'if .truncated then error("truncated") else .tree[].path end' 2>/dev/null); then
        # A here-string, not a pipe. `grep -q` exits at the first match, the
        # writer of a pipe then dies of SIGPIPE on a large tree, and under
        # pipefail the condition reads false: gibson, whose tree is the
        # largest, was reported with no CodeQL workflow in the first live run.
        manifests=$(grep -cE "$MANIFEST_RE" <<<"$tree" || true)
        if grep -qiE "$CODEQL_WORKFLOW_RE" <<<"$tree"; then
          codescan="workflow"
        elif [ "$(gh api "repos/${ORG}/${name}/code-scanning/default-setup" --jq '.state' 2>/dev/null)" = "configured" ]; then
          codescan="default-setup"
        else
          codescan="none"
        fi
      else
        manifests="unreadable"; codescan="unreadable"
      fi
      dependabot=$(gh api "repos/${ORG}/${name}/automated-security-fixes" --jq '.enabled' 2>/dev/null) || dependabot="unreadable"

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$vis" "$lang" "$(g secret_scanning)" \
        "$(g secret_scanning_push_protection)" "$(g code_security)" \
        "$manifests" "$dependabot" "$codescan"
    done
}

# The three org-wide Actions settings #75 measured wrong on 2026-09-16. They
# live only in the org UI: nothing in git records them and nothing failed when
# they changed, which is how they stayed wrong for as long as they did. Read
# from the same two endpoints the audit read them from.
fetch_org() {
  if [ -n "${ORG_SETTINGS_FETCH_CMD:-}" ]; then
    eval "$ORG_SETTINGS_FETCH_CMD"
    return
  fi
  local wf perm
  wf=$(gh api "/orgs/${ORG}/actions/permissions/workflow" 2>/dev/null) || wf='{}'
  perm=$(gh api "/orgs/${ORG}/actions/permissions" 2>/dev/null) || perm='{}'
  # NOT `// "absent"`: jq's alternative operator substitutes for false as
  # well as null, so a boolean that is legitimately false read as "absent" and
  # the guard cried drift on a correct setting. Test presence explicitly.
  field() { printf '%s' "$1" | jq -r --arg k "$2" 'if has($k) and .[$k] != null then (.[$k]|tostring) else "absent" end'; }
  printf '%s\t%s\t%s\n' \
    "$(field "$wf" default_workflow_permissions)" \
    "$(field "$wf" can_approve_pull_request_reviews)" \
    "$(field "$perm" sha_pinning_required)"
}

drift=0
checked=0

while IFS=$'\t' read -r name vis lang secret push code manifests dependabot codescan; do
  [ -z "${name:-}" ] && continue
  checked=$((checked + 1))

  # --- tier 1: universal ------------------------------------------------------
  if [ "$secret" != "enabled" ]; then
    echo "DRIFT ${name}: secret scanning is '${secret}' — ADR-0088 tier 1 is every repo, no exceptions" >&2
    drift=$((drift + 1))
  fi
  if [ "$push" != "enabled" ]; then
    echo "DRIFT ${name}: push protection is '${push}' — ADR-0088 tier 1 is every repo, no exceptions" >&2
    drift=$((drift + 1))
  fi

  # --- tier 2: CodeQL-supported languages, private repos ----------------------
  # `absent` means GitHub did not report the field, which is what public repos
  # do. Nothing to enforce there.
  if [ "$code" != "absent" ] && [ "$code" != "enabled" ]; then
    for l in $CODEQL_LANGS; do
      if [ "$l" = "$lang" ]; then
        echo "DRIFT ${name}: code scanning is '${code}' and its language is ${lang} — ADR-0088 tier 2" >&2
        drift=$((drift + 1))
        break
      fi
    done
  fi

  # --- tier 2: CodeQL-supported languages, public repos -----------------------
  # A public repo does not report code_security. Its code scanning is a CodeQL
  # workflow on the default branch or default setup.
  if [ "$vis" = "public" ]; then
    for l in $CODEQL_LANGS; do
      if [ "$l" = "$lang" ] && [ "${codescan:-unreadable}" != "workflow" ] && [ "${codescan:-unreadable}" != "default-setup" ]; then
        echo "DRIFT ${name}: public, language ${lang}, and code scanning is '${codescan:-unreadable}' (no CodeQL workflow on the default branch and no default setup) — ADR-0088 tier 2" >&2
        drift=$((drift + 1))
        break
      fi
    done
  fi

  # --- tier 3: Dependabot security updates, every repo with a manifest ---------
  case "${manifests:-unreadable}" in
    0) ;;
    ''|*[!0-9]*)
      echo "DRIFT ${name}: the tree of the default branch could not be read, so tier 3 was not decided — ADR-0088 tier 3" >&2
      drift=$((drift + 1))
      ;;
    *)
      if [ "${dependabot:-unreadable}" != "true" ]; then
        echo "DRIFT ${name}: ${manifests} dependency manifest(s) and Dependabot security updates is '${dependabot:-unreadable}' — ADR-0088 tier 3" >&2
        drift=$((drift + 1))
      fi
      ;;
  esac
done < <(fetch)

# Org-wide Actions settings (#75). One record; any wrong value is drift.
IFS=$'\t' read -r wf_perm can_approve sha_pin < <(fetch_org)
if [ "${wf_perm:-absent}" != "read" ]; then
  echo "DRIFT org: default_workflow_permissions is '${wf_perm:-absent}' — must be 'read'. A workflow that omits its own permissions: block otherwise gets a read-write GITHUB_TOKEN (#75)" >&2
  drift=$((drift + 1))
fi
if [ "${can_approve:-absent}" != "false" ]; then
  echo "DRIFT org: can_approve_pull_request_reviews is '${can_approve:-absent}' — must be 'false'. An Actions run must not be able to approve a pull request (#75)" >&2
  drift=$((drift + 1))
fi
if [ "${sha_pin:-absent}" != "true" ]; then
  echo "DRIFT org: sha_pinning_required is '${sha_pin:-absent}' — must be 'true'. The unpinned-actions guard should be redundant, not load-bearing (#75)" >&2
  drift=$((drift + 1))
fi

if [ "$checked" -eq 0 ]; then
  echo "FAIL: no repositories were checked — an empty scan would pass vacuously" >&2
  exit 1
fi

if [ "$drift" -gt 0 ]; then
  cat >&2 <<'MSG'

ADR-0088 says a repo is exempt from a tier only when the tier CANNOT PHYSICALLY
APPLY — never because the repo is small, internal, private, or "just tooling".

Fix by turning the feature on, not by adding an exemption:

  gh api -X PATCH repos/<org>/<repo> \
    -f 'security_and_analysis[secret_scanning][status]=enabled' \
    -f 'security_and_analysis[secret_scanning_push_protection][status]=enabled'

  gh api -X PUT repos/<org>/<repo>/automated-security-fixes        # tier 3
  gh api -X PATCH repos/<org>/<repo>/code-scanning/default-setup -f state=configured   # tier 2, public

The three org settings are fixed in the org UI (Settings > Actions > General), or:
  gh api -X PUT orgs/<org>/actions/permissions/workflow \
    -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
  gh api -X PUT orgs/<org>/actions/permissions -F sha_pinning_required=true
If a repo genuinely cannot carry a tier, that needs a new ADR superseding 0088
which names the repo and the reason.
MSG
  echo "FAIL: ${drift} setting(s) drifted from ADR-0088 across ${checked} repos" >&2
  exit 1
fi

echo "ok  ${checked} repos match ADR-0088 (tier 1 universal, tier 2 by language, tier 3 by manifest); org Actions settings match #75"
