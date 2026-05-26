## Summary
<!-- 1-3 bullets: what changed and why. The "why" is more important than the "what". -->

## Linked epic
<!-- Project board URL if this PR is part of a cross-repo epic, else "n/a" -->

## Linked spec
<!-- Path under .spec-workflow/specs/ if applicable, else "n/a". Note: spec-workflow is local-only, not version-controlled. -->

## Risk
<!-- low | medium | high -->

## Rollback plan
<!-- One sentence: revert PR, redeploy previous tag, etc. -->

## Test plan
- [ ] CI green (required)
- [ ] <feature-specific verification>

## Production impact (delete if low risk)
<!-- For tier-platform-release repos (sdk, deploy, gitops): -->
- [ ] production-impact-acknowledged
- Affected systems:
- Customer-visible? yes / no

<!--
========================================================================
DOCS COVERAGE TRAILER — REQUIRED

Pick exactly ONE of these and uncomment it. The `architectural-doc-coverage`
CI check parses your PR body for one of these trailers and blocks merge
otherwise.

Trailer (a) — companion PR on zeroroot-ai/docs that updates the relevant
page (architecture/, repos/<repo>/, edge-cases/, or adr/):

    Docs-PR: https://github.com/zeroroot-ai/docs/pull/<N>

Trailer (b) — cosmetic/mechanical fix that touches no architectural
invariant (typo, dep bump, formatting, comment-only). Reviewers will push
back on routine use of this escape hatch.

    Docs-PR: not-applicable: <one-sentence why>

Workspace CLAUDE.md → "Close the loop with documentation".
========================================================================
-->

Docs-PR:
