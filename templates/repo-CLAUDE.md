# <repo> — CLAUDE.md

> **Workflow rules:** see [`zero-day-ai/.github` → `AGENTS.md`](https://github.com/zero-day-ai/.github/blob/main/AGENTS.md) — canonical for branching / commits / PRs / releases / merging. Conventional Commits MANDATORY. Never push to main. Never force-push.

This file is the per-repo addendum. Workspace-wide concerns live in [`~/Code/zero-day.ai/CLAUDE.md`](https://github.com/zero-day-ai/.github/blob/main/AGENTS.md); architectural decisions in [`docs/adr/`](https://github.com/zero-day-ai/docs/tree/main/adr).

## TL;DR

<!-- 2-3 sentences describing what this repo is and the canonical agent-entry-point command -->

## Architecture

<!-- One paragraph orientation. Cross-link to the canonical architecture doc. -->

## Regen commands

<!-- proto regen, codegen, authz-registry — whichever apply to this repo. Omit if N/A. -->

```bash
# Examples — adapt:
# make proto              # regenerate proto bindings
# make authz-registry     # regenerate authz registry artifacts
# make manifests generate # regenerate kubebuilder CRDs / zz_generated
```

## Gotchas

<!-- Repo-specific traps. Cross-link to docs/agents/traps.md entries via `// trap: T<NNNN>` references. -->

## Links

- Org-level workflow: [`AGENTS.md`](https://github.com/zero-day-ai/.github/blob/main/AGENTS.md)
- Workspace map: workspace `CLAUDE.md`
- Per-repo ADRs: [`docs/repos/<repo>/adr/`](https://github.com/zero-day-ai/docs/tree/main/repos)
- Domain glossary: [`docs/glossary.md`](https://github.com/zero-day-ai/docs/blob/main/glossary.md)
- PR checklist: [`docs/agents/pr-checklist.md`](https://github.com/zero-day-ai/docs/blob/main/agents/pr-checklist.md)
