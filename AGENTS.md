# AI agent runbook for `zero-day-ai/*`

This file is the contract every AI agent (Claude Code, opencode, others) reads
before doing any work in this org. It is agent-agnostic; the same rules apply
whether you are a human or an LLM-driven session. Per-repo `CLAUDE.md` files
override only when explicitly noted.

## tl;dr (for agents skimming)

1. **Never push to `main`.** Branch, open a PR, wait for CI.
2. **Conventional Commits everywhere.** PR title is the squash-merge subject and
   drives release-please. Malformed title → `pr-title-lint` fails → no merge.
3. **Three branch patterns:** `epic/<id>-<slug>`, `feat/<short>`, `fix/<short>`.
4. **Cross-repo work goes on a Project board** named `Epic: <id>`. Find or create
   the board, add your PRs as items.
5. **Rebase, never merge.** `git fetch origin && git rebase origin/main`.
6. **Squash-merge only**, ruleset-enforced. Multi-commit PRs are fine; the
   squash subject is set from the PR title.
7. **Agents may self-merge low-risk PRs on green CI** — see §5 for the gate.
   `feat:` and any `BREAKING CHANGE` still require a human.
8. **CI failures must be root-caused, not retried.** Open or update a
   `ci-failure` issue (the `ci-failure-triage` workflow does this automatically;
   you add the diagnosis as a comment) before pushing a fix or rerunning.
9. **One code path** ([ADR-0003](https://github.com/zero-day-ai/docs/blob/main/adr/0003-one-code-path.md)).
   Every dependency is required at chart render, at process boot, and at runtime.
   No `.enabled: false` toggles, graceful-nil branches, silent env fallbacks,
   `failurePolicy: Ignore`, or `--dev-mode` flags. CI enforces (see §10).

---

## 1. Before you start

Run, in this order:

```bash
# What's already in flight under your name?
for repo in gibson sdk ext-authz dashboard tenant-operator deploy gitops \
            debug-plugin setec adk gibson-tool-runner spiffe-jwks-exporter; do
  gh pr list -R zero-day-ai/$repo --state open \
    --search "author:@me OR assignee:@me" --json number,title,headRefName
done

# What epics are open?
gh project list --owner zero-day-ai --format json \
  | jq '.projects[] | select(.title | startswith("Epic:")) | {number, title}'
```

If you are joining a named epic, view its board first:

```bash
gh project view <num> --owner zero-day-ai
```

**Never start a branch whose slug matches an existing in-flight branch in any repo.**
If your work belongs to an open epic, use that epic's branch name across all repos
you touch.

---

## 2. Branching — exactly three patterns

| Pattern | Use when | Example |
|---------|----------|---------|
| `epic/<id>-<slug>` | Work touches ≥2 repos OR is part of a tracked epic | `epic/agent-credentials-cutover` |
| `feat/<short-slug>` | Single-repo additive change | `feat/cron-checkpoint-ttl` |
| `fix/<short-slug>` | Single-repo bug fix | `fix/grpc-timeout-leak` |

`<id>` matches the slug after `Epic:` in a Project board name (e.g., board
"Epic: agent-credentials-cutover" → branch `epic/agent-credentials-cutover`
in every repo touched).

**Never** push directly to `main`. Org rulesets reject this.

---

## 3. Committing

**Conventional Commits are MANDATORY** — release-please uses commit subjects
to decide version bumps and write CHANGELOGs.

Allowed prefixes:
- `feat:` — minor version bump
- `fix:` — patch version bump
- `chore:`, `docs:`, `refactor:`, `test:`, `perf:`, `build:`, `ci:`, `revert:` — no version bump

Breaking changes:
```
feat(authz)!: rename ComponentGrant → AccessGrant

BREAKING CHANGE: Existing FGA tuples must be migrated via `gibson migrate authz`.
```

The `!` marker AND the `BREAKING CHANGE:` footer trigger a major version bump.

**Required trailers on every commit:**
- `Co-Authored-By:` (existing org convention)
- For epic work: `Refs: epic/<id>` (so cross-repo work is greppable)

**Never** use `--no-verify`. Pre-commit hooks (gitleaks, large-file checks)
exist for a reason; if they block, fix the underlying issue.

---

## 4. Opening PRs

```bash
gh pr create \
  --title "feat(scope): <conventional-commit subject>" \
  --body "$(cat <<'EOF'
## Summary
<1-3 bullets — what changed, why>

## Linked epic
<board URL or "n/a">

## Linked spec
<.spec-workflow path or "n/a"; this is local-only, not version-controlled>

## Risk
low | medium | high

## Rollback plan
<one sentence: revert PR, redeploy previous tag, etc.>

## Test plan
- [ ] CI green (required)
- [ ] <feature-specific verification>

Generated with Claude Code
EOF
)"
```

**PR title is critical.** Squash-merge means the PR title becomes the merged
commit subject. release-please reads that subject. A malformed title silently
breaks the release flow — `pr-title-lint` enforces this.

**Open ready-for-review, never `--draft`.** Required checks run on draft and
non-draft alike, but the merge button is disabled while a PR is draft — so
draft PRs make a human flip a toggle for no reason. If you want CI to run
without inviting a merge yet, just say so in the PR body.

**Add to the epic board** if this PR is part of one:

```bash
gh project item-add <project-num> --owner zero-day-ai --url <pr-url>
```

The board's built-in automation moves the item through `Todo → In Progress →
In Review → Done` based on PR state. Agents do not update the board manually
once the item is added.

---

## 5. Rebasing, merging, and the agent self-merge gate

**Squash-merge only**, ruleset-enforced. Org settings disable merge-commit and
rebase-merge.

**Conflicts** — always rebase onto latest origin/main:

```bash
git fetch origin
git rebase origin/main
# resolve conflicts
git rebase --continue
git push --force-with-lease
```

**Never** `git merge main` into a feature branch — squash + a merge commit
in history confuses release-please's commit walking.

**Generated files** (`internal/authz/registry/`, `src/gen/`, proto-generated):
regenerate from source rather than hand-resolving conflicts:

```bash
# In core/gibson:
make authz-registry && make proto

# In dashboard:
pnpm proto:generate
```

### Agent self-merge gate

Agents may merge their own PRs **only when all of the following hold**:

| # | Condition |
|---|-----------|
| 1 | Every required status check is `success` (not `pending`, not `neutral`, not skipped). Verify with `gh pr checks <num>`. |
| 2 | The PR title prefix is one of: `fix:`, `chore:`, `docs:`, `test:`, `ci:`, `refactor:`, `build:`, `perf:`, `revert:`. **OR** the PR is a release-please release PR, **OR** an SDK fan-out `chore(deps): bump sdk to ...` PR. |
| 3 | No `BREAKING CHANGE` footer and no `!` marker in the title. |
| 4 | No unresolved review threads (the `tier-core` ruleset blocks merge otherwise, but check first to avoid a wasted call). |
| 5 | Branch is rebased onto the current `origin/main` (no "out of date" warning in the PR). |
| 6 | The repo is **not** under `tier-platform-release` (sdk / deploy / gitops) — those require a code-owner human review. |

**`feat:`, `feat!:`, anything with `BREAKING CHANGE`, and any PR on
`sdk` / `deploy` / `gitops` always need a human merge.**

When the gate is met, merge with:

```bash
gh pr merge <pr-number> --squash --delete-branch
```

When it isn't, leave the PR for a human and move on to the next task in your
queue. Do not "encourage" the merge with comments or pings.

**You are responsible for the judgment call.** "All checks green" is a
necessary condition, not a sufficient one — if you have any reason to suspect
the change is riskier than it looks (touches auth paths, modifies the daemon's
public surface, changes Helm chart defaults, edits CI itself), leave it for a
human even if the table above says you may merge.

---

## 6. CI failures: triage, file an issue, then fix

When a required check fails on your PR (or on `main` after merge):

1. **Do not blindly rerun** the workflow. The `ci-failure-triage` workflow
   (a `workflow_run` listener wired in each repo, calling the reusable workflow
   at `zero-day-ai/.github/.github/workflows/ci-failure-triage.yml`) opens or
   updates a `ci-failure`-labelled issue with the failed-jobs list, the run
   URL, the head SHA, and the branch. **One issue per `(workflow, branch)`
   pair** — if the issue already exists, the workflow comments on it instead
   of opening a duplicate.
2. **Read the failed job's logs** (`gh run view <run-id> --log-failed`) and
   identify the root cause:
   - **Real failure** — your change broke something. Fix it, push, the existing
     issue auto-closes when the next run on the same branch+workflow succeeds.
   - **Flake** (network blip, transient registry timeout, known-flaky test) —
     post a comment on the issue with the evidence (link to the specific log
     line, prior occurrences if any) and rerun **once**. If it flakes again,
     it's not a flake; treat as real and fix.
   - **Infra** (runner died, action upstream broke, secrets rotated badly) —
     comment with the diagnosis and `@`-mention the operator. Do not rerun.
3. **Never rerun a failing job without posting the diagnosis as a comment
   first.** The issue trail is how we notice patterns across repos.
4. **Never `--no-verify` past a failing pre-commit hook**, never disable a
   failing required check in the ruleset, never add `continue-on-error: true`
   to silence a check.

The reusable triage workflow auto-closes the issue when a subsequent run of
the same workflow on the same branch succeeds, with a "Resolved by run …"
comment. If you fixed something *outside* CI that resolved a flake, close the
issue manually with a one-line note explaining what you did.

---

## 7. After merge

The ruleset deletes your remote branch automatically. Locally:

```bash
git checkout main
git fetch --prune
git branch -D <merged-branch>
```

The Project board's "PR merged → Done" automation flips the item state.
**Do not** edit the board manually.

For `core/sdk` merges, the SDK fan-out workflow opens 6 consumer-bump PRs
(one per Go consumer) within ~5 minutes of the SDK tag being cut. Wait for
those PRs to appear before starting downstream work in those consumers.

---

## 8. Cross-repo epics

Anything spanning ≥2 repos is an epic. Each epic gets:

1. **A Project (v2) board** at the org level: `gh project create --owner zero-day-ai --title "Epic: <id>"`
2. **A consistent branch name** across every repo: `epic/<id>-<slug>` (or just `epic/<id>` if no slug needed).
3. **Items**: every PR added via `gh project item-add`.

The Project board is the single source of truth for "what is in flight." Use
it instead of grepping branches across 12 directories.

**Active epics today** (each has an existing branch in 5+ repos that needs to
be renamed to `epic/<id>` during housekeeping):

- `epic/agent-credentials-cutover`
- `epic/tenant-role-taxonomy`
- `epic/zero-trust-hardening`
- `epic/discovery-bitfield-coherence`
- `epic/self-mode-authz`

---

## 9. Releases

You do **not** cut releases by hand. release-please runs on every push to
`main` in every repo. It opens an auto-generated "release PR" that bumps the
version + writes the CHANGELOG. When a human merges the release PR, the tag
is created automatically and the per-repo image-build workflow fires.

**SDK releases trigger the fan-out**: when a `core/sdk` tag is published, a
workflow opens `chore(deps): bump sdk to vX.Y.Z` PRs in each of the 6 Go
consumers. Those PRs auto-merge if their CI passes.

If you need an out-of-band release (rare), open an issue first; do not hand-tag.

### 9a. We are pre-1.0 — use `feat!:` freely, do NOT bump major by accident

Every repo in this polyrepo is pre-1.0 software. The platform has not made
a stability claim on any public surface yet. Reach 1.0 deliberately, not
because release-please saw a single `feat!:` commit and obeyed Conventional
Commits literally.

Every repo's `release-please-config.json` carries `"bump-minor-pre-major":
true`. While a package is below 1.0.0, this setting tells release-please
that `feat!:` and `BREAKING CHANGE:` commits bump **minor**, not major —
e.g. `0.103.0 → 0.104.0` instead of `1.0.0`. Use the breaking-change
syntax freely for semantic accuracy; the config does the right thing.

**Cutting a real 1.0.0 release is a deliberate human decision, never automatic.**
The procedure for any future 1.0.0 cut on any repo:

1. Open an issue proposing the stability claim — what's stable, what's
   covered by SemVer guarantees going forward, what's still out of scope.
2. Get explicit sign-off from a code owner. Async is fine; the explicit
   approval is the gate.
3. In the same PR that cuts 1.0: remove `"bump-minor-pre-major": true`
   from that repo's `release-please-config.json`, write a commit body that
   names the stability claim, merge.
4. release-please's next cycle proposes `1.0.0` from the accumulated
   commit history; that release PR gets the same code-owner sign-off
   before merge.

Reviewers should reject any PR titled with a `1.0.0` or `2.0.0` (etc.)
bump unless the proposing issue exists and was approved.

Historical context: on 2026-05-17 a `feat!:` PR on `core/sdk` reflexively
crossed the polyrepo from 1.9.0 to 2.0.0, then bricked the SDK fan-out
because Go's v2+ module-path rule requires `/v2` and the SDK doesn't have
it. Recovery: full polyrepo reset back to 0.x (PRD
zero-day-ai/.github#25). The `bump-minor-pre-major` setting is the only
structural change that prevents repeat.

---

## 10. Hard prohibitions (CI-enforced where possible)

- **No `go.work`** at any repo root. Cross-module changes go through SDK tag → consumer bump.
- **No `replace` directives** in `go.mod`.
- **No git submodules.**
- **No `--no-verify`** on commits.
- **No `--force-push` to main** (rejected by ruleset).
- **No direct push to main** (rejected by ruleset).
- **No `--no-gpg-sign`** (signed commits required by ruleset on production-tier repos).
- **No agent self-merge of `feat:` / `feat!:` / `BREAKING CHANGE` PRs**, and no
  agent self-merge on `sdk` / `deploy` / `gitops` regardless of scope (see §5).
- **No rerunning a failed CI job without first posting a root-cause comment**
  on the `ci-failure` issue the triage workflow opened (see §6).
- **One code path — see [ADR-0003](https://github.com/zero-day-ai/docs/blob/main/adr/0003-one-code-path.md).**
  Never re-introduce `.enabled: false` defaults, `| default ""` silent template
  fallbacks, `failurePolicy: Ignore` webhooks, `optional: true` env refs,
  `lookup` calls outside bootstrap templates, `noopAuthorizer` / `NoopClient` /
  `NullSender` injections, `GIBSON_MODE` / `--dev-mode` / `require_ready=false`
  flags, or `process.env.X ?? "default"` fallbacks for required config. Every
  dependency is required at chart render, at process boot, and at runtime;
  failure surfaces at install time, never at "user clicks panel" time. The
  cross-chart-check tool plus the Go AST `no-graceful-nil` contract test
  enforce this on every PR.

The `no-monorepo-shortcuts` workflow runs as a required check on every PR
across every repo and will fail any PR that introduces `go.work`, `replace`,
or `.gitmodules`.

---

## 11. When in doubt

- Read the per-repo `CLAUDE.md`. It overrides this file when explicitly noted.
- Check `gh ruleset list --org zero-day-ai` to see what's actually enforced.
- Open a PR (ready-for-review, not draft) early and let CI tell you what's wrong.
- If a ruleset blocks something legitimate, ask the operator — they have
  bypass during the soft-launch period; tightening happens after the rules
  prove themselves.
- If a `ci-failure` issue is open against a workflow you're about to touch,
  read the latest comment first — the previous agent's diagnosis usually saves
  you a re-debug.
