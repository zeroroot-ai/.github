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
# Only tiers 1 and 2 are enforced here, and deliberately:
#
#   Tier 1 needs no judgment. It is universal, so there is nothing to decide and
#   nothing to exempt, which is what makes it enforceable without a config file
#   that would itself drift.
#
#   Tier 2 is decided from the repo's own primary language, which GitHub
#   reports. Public repos return `null` for code_security because CodeQL there
#   is configured by workflow rather than by this setting, so they are skipped
#   rather than guessed at.
#
#   Tier 3 is NOT enforced. Deciding "has a dependency graph" means reading the
#   tree for manifests and workflows, and a guard that is wrong about that would
#   fail builds for repos that legitimately have nothing to scan. A wrong guard
#   is worse than no guard.
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
          | [.name, (if .private then "private" else "public" end), (.language // "-")]
          | @tsv' \
  | while IFS=$'\t' read -r name vis lang; do
      sa=$(gh api "repos/${ORG}/${name}" --jq '.security_and_analysis' 2>/dev/null)
      g() { printf '%s' "$sa" | jq -r ".$1.status // \"absent\"" 2>/dev/null; }
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$name" "$vis" "$lang" "$(g secret_scanning)" \
        "$(g secret_scanning_push_protection)" "$(g code_security)"
    done
}

drift=0
checked=0

while IFS=$'\t' read -r name vis lang secret push code; do
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
done < <(fetch)

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

If a repo genuinely cannot carry a tier, that needs a new ADR superseding 0088
which names the repo and the reason.
MSG
  echo "FAIL: ${drift} setting(s) drifted from ADR-0088 across ${checked} repos" >&2
  exit 1
fi

echo "ok  ${checked} repos match ADR-0088 (tier 1 universal, tier 2 by language)"
