# Contributing to `.github`

This repository holds org-wide GitHub configuration: reusable workflows, rulesets, templates and the agent workflow contract. Changes here affect every repository in the organization.

If anything here is unclear, open an issue rather than guessing — an unclear
contributing guide is a bug in this file.

## Prerequisites

- `bash`, `python3`, `jq`, `gh`
- No build step; everything here is configuration and shell.

## Build and test

```sh
bash scripts/test-ruleset-drift.sh
bash scripts/test-required-contexts.sh
bash scripts/test-security-features-drift.sh
```

## The merge gate

Two rules specific to this repo:

**Rulesets are code.** `rulesets/*.json` is the source of truth. Editing a
ruleset in the GitHub UI does not stick — `apply-rulesets.yml` overwrites live
state from the files on the next merge, so a UI change is pending deletion.

**Every guard ships with a failing fixture in the same PR.** A guard that cannot
go red is worse than no guard, because it gets read as evidence. The mutation
suites above run on every pull request without secrets, so they gate. If you add
a guard, add its `test-*.sh` alongside it.

Every pull request runs it. A red gate is a real signal: **do not** disable a
guard to get a PR through. If a guard is wrong, fix the guard in the same PR
and say why — a guard that needs re-pinning after an unrelated edit is a defect
in the guard.

## Pull requests

- **Conventional Commits in the PR title** — `feat:`, `fix:`, `chore:`,
  `docs:`, `ci:`, `test:`, `refactor:`. The subject must start lowercase;
  `pr-title-lint` enforces both.
- **One root cause per PR.** Two unrelated fixes are two pull requests.
- **Rebase, never merge.** `git fetch origin && git rebase origin/main`
- Releases are automatic via release-please. Never hand-tag, never hand-edit a
  version.

## Reporting a security issue

Do not open a public issue. See [SECURITY.md](SECURITY.md).

## License

Apache-2.0 — see [LICENSE](LICENSE). These workflows exist to be reused and copied.
