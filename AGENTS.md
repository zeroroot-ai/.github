# Contributor and agent guide for `zeroroot-ai/*`

This file is the contribution contract for every `zeroroot-ai` repository. The
same rules apply to a human contributor and to an AI coding agent (Claude Code,
opencode, or any other). A repository may add a `CONTRIBUTING.md` with
repo-specific detail, but this guide is the baseline.

## tl;dr

1. Never push to `main`. Branch, open a pull request, and let CI run.
2. Use Conventional Commits everywhere. The pull-request title is the
   squash-merge subject and drives the release tool.
3. Use one of three branch patterns: `epic/<id>-<slug>`, `feat/<short>`,
   `fix/<short>`.
4. Rebase onto `main`. Never merge `main` into your branch.
5. Squash-merge only. The merge is allowed only when every required check is
   green.
6. Keep one code path. Every dependency is required at build, at boot, and at
   runtime. No disable toggles or silent fallbacks.
7. The Apache `sdk` is the only public API surface. It must not import the
   `gibson` daemon.

## 1. Branching

Use exactly three patterns.

| Pattern | Use when | Example |
|---|---|---|
| `epic/<id>-<slug>` | The work touches two or more repos, or belongs to a tracked epic | `epic/agent-credentials` |
| `feat/<short-slug>` | A single-repo additive change | `feat/cron-checkpoint-ttl` |
| `fix/<short-slug>` | A single-repo bug fix | `fix/grpc-timeout-leak` |

Org rulesets reject a direct push to `main`.

## 2. Commits

Conventional Commits are mandatory. The release tool reads commit subjects to
choose the version bump and write the changelog.

Allowed prefixes:
- `feat:` — minor version bump
- `fix:` — patch version bump
- `chore:`, `docs:`, `refactor:`, `test:`, `perf:`, `build:`, `ci:`, `revert:` —
  no version bump

Mark a breaking change with a `!` and a footer:

```
feat(authz)!: rename ComponentGrant to AccessGrant

BREAKING CHANGE: existing grants migrate with `gibson migrate authz`.
```

Every commit carries a `Co-Authored-By:` trailer. Never use `--no-verify`. The
pre-commit hooks (secret scan, large-file check) exist for a reason. If a hook
blocks you, fix the cause.

## 3. Pull requests

Open a pull request ready for review, never as a draft. Required checks run
either way, and a draft only makes a reviewer flip a toggle.

The pull-request title is critical. A squash-merge uses the title as the merged
commit subject, and the release tool reads that subject. A malformed title
breaks the release flow, so `pr-title-lint` enforces the Conventional Commits
form.

Use a closing keyword in the pull-request body, in the `Fixes #N` form for the
same repo or the fully qualified `Fixes owner/repo#N` form across repos. The
bare `repo#N` shorthand is not a valid GitHub closing reference. It renders as a
link but leaves the issue open after the merge.

A useful body states the change, the risk, the rollback, and the test plan.

## 4. Rebase and merge

Squash-merge is the only merge style. Org settings disable merge commits and
rebase merges.

Resolve conflicts by rebasing onto the latest `main`:

```bash
git fetch origin
git rebase origin/main
git push --force-with-lease
```

Never run `git merge main` into a feature branch. A merge commit in the branch
history confuses the release tool's commit walk.

Regenerate generated files from source rather than resolve them by hand.

A pull request merges only when every required check reports success. Merge
with:

```bash
gh pr merge <number> --squash --delete-branch
```

Some repositories run a merge queue. There, enable auto-merge and let the queue
land the change.

## 5. CI failures

Root-cause a failure. Never rerun a failed job blind, and never silence a check.

1. Read the failed job's logs: `gh run view <run-id> --log-failed`.
2. If your change broke something, fix it and push.
3. If a check is a genuine flake, say so with evidence, then rerun once. A
   second failure is not a flake.

Never pass `--no-verify`, never disable a required check, and never add
`continue-on-error: true` to hide a failure.

## 6. Releases

You do not cut releases by hand. The release tool runs on every push to `main`.
It opens a release pull request that bumps the version and writes the changelog.
Merging that pull request creates the tag and fires the image build.

Every repository is pre-1.0. Each `release-please-config.json` sets
`bump-minor-pre-major: true`, so a `feat!:` or `BREAKING CHANGE:` commit bumps
the minor version, not the major. Use the breaking-change form freely for
semantic accuracy. The config keeps the version below 1.0.

A real 1.0 release is a deliberate decision by the repository owner, never
automatic. Propose the stability claim in an issue first, get sign-off, and only
then remove `bump-minor-pre-major` in the same pull request that cuts 1.0.

## 7. Hard prohibitions

CI enforces these where it can.

- No `go.work` at any repo root.
- No `replace` directives in `go.mod`.
- No git submodules.
- No `--no-verify` on commits.
- No direct push or force-push to `main` (the ruleset rejects both).
- No rerun of a failed check without a root-cause note first.
- **One code path.** Never add a disable toggle, a silent default fallback, an
  ignore-on-failure webhook, an optional required-config reference, or a
  dev-mode flag. Every dependency is required at build, at boot, and at runtime,
  so a failure surfaces at install time, never when a user clicks a panel. See
  ADR-0003.

The `no-monorepo-shortcuts` check fails any pull request that adds `go.work`, a
`replace` directive, or a submodule.

## 8. The open-core API surface

There is one public API surface: the Apache-2.0 `sdk`. It carries the
component-development protos only, which are the agent, tool, plugin, component,
harness, and mission types. It ships no admin RPCs and no infrastructure
dependencies, and it must not import the `gibson` daemon. The check
`make check-no-gibson` enforces that boundary, and a CodeQL deny-list fails CI
if the SDK's module graph pulls a secrets backend, a database client, or any
other first-party infrastructure client.

Everything that operates the platform lives inside the `gibson` monorepo. The
admin, operator, and billing protos are daemon-local under
`internal/server/daemon/api/gibson/<pkg>/v1`. The shared Go primitives live
under `internal/infra`.

| Tier | Repos | Role |
|---|---|---|
| Apache-2.0 | `sdk`, `adk`, `setec`, `gibson-executor`, `charts` | The build-and-run community surface. `sdk` is the component-dev protos only. `charts` is the umbrella Helm chart. |
| Elastic License v2 | `gibson`, `dashboard` | The platform. `gibson` is the daemon monorepo, which also holds the operators and ext-authz. |
| Closed | `billing` | The Stripe backend, injected into `gibson` through a seam. |
| Private, not distributed | `hosted` | The ZeroRoot cloud estate. |

## 9. Writing rules

Write every document a person reads in Simplified Technical English
(ASD-STE100). That covers READMEs, docs pages, pull-request descriptions, issue
bodies, and error messages.

Words:
- Use one name for one thing.
- Use the short common word: start, use, help, make sure, before, after, about,
  get, show, also.
- Give each word one meaning.
- No marketing adjectives such as seamless, robust, powerful, or world-class.
- American spelling, never British spelling.

Verbs and sentences:
- Use the active voice. Write "the parser reads the file".
- Use a verb for an action. Write "analyze the log", not "perform an analysis".
- Write one instruction per sentence, at most 20 words. A descriptive sentence
  is at most 25 words.
- No contractions. Use the articles a, an, the, this, these.

Punctuation and structure:
- No semicolons. Write two sentences.
- No em dash or en dash as punctuation.
- One topic per paragraph, at most six sentences.
- For steps, use a numbered list, one action per item, in the imperative.
- Put a condition before its command.

## 10. When in doubt

- Read the repository's own `README` and `CONTRIBUTING`.
- Run `gh ruleset list --org zeroroot-ai` to see what the org actually enforces.
- Open a pull request early, ready for review, and let CI tell you what is
  wrong.
