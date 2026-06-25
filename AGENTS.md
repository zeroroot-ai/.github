# AI agent runbook for `zeroroot-ai/*`

This file is the contract every AI agent (Claude Code, opencode, others) reads
before doing any work in this org. It is agent-agnostic; the same rules apply
whether you are a human or an LLM-driven session. Per-repo `CLAUDE.md` files
override only when explicitly noted.

## tl;dr (for agents skimming)

1. **Never push to `main`.** Branch, open a PR, wait for CI (or test locally and merge if GitHub Actions credits are exhausted — see §5).
2. **Every user-reported issue starts with a tracker search — open AND closed.**
   Before reading code, sketching a fix, or filing a new issue, search the
   relevant repo(s) across both states for matching text. Three outcomes
   gate the next step: (a) open issue matches → link it, continue from its
   diagnosis; (b) closed issue matches but the user's new evidence shows
   it's still broken → `gh issue reopen <n> --comment "<new evidence>"`,
   continue from there; (c) no match → file via `/to-issues`. Never start
   fresh work on something a prior agent already filed. Detail in §1.
3. **Conventional Commits everywhere.** PR title is the squash-merge subject and
   drives release-please. Malformed title → `pr-title-lint` fails → no merge.
3. **Three branch patterns:** `epic/<id>-<slug>`, `feat/<short>`, `fix/<short>`.
4. **Cross-repo work goes on a Project board** named `Epic: <id>`. Find or create
   the board, add your PRs as items.
5. **Rebase, never merge.** `git fetch origin && git rebase origin/main`.
6. **Squash-merge only**, ruleset-enforced. Multi-commit PRs are fine; the
   squash subject is set from the PR title.
7. **Agents merge their own PRs once required CI is green — across all repos, all commit types**
   ([ADR-0007](https://github.com/zeroroot-ai/docs/blob/main/adr/0007-agent-merge-autonomy.md)).
   The CI rulesets are the gate; commit-type prefix, repo tier, and `BREAKING CHANGE` status
   are not. **Exception: if GitHub Actions credits are exhausted, run local tests and merge on
   local pass — do not stop work waiting for credits to replenish.** The single remaining
   filter is agent judgment: if a human decision is genuinely needed, halt and surface an
   `AGENT BLOCKED` banner at the top of the terminal reply, then stop. No polling, no
   wake-up loops, no background monitors on human replies — see §5.
8. **CI failures must be root-caused, not retried.** Open or update a
   `ci-failure` issue (the `ci-failure-triage` workflow does this automatically;
   you add the diagnosis as a comment) before pushing a fix or rerunning.
9. **One code path** ([ADR-0003](https://github.com/zeroroot-ai/docs/blob/main/adr/0003-one-code-path.md)).
   Every dependency is required at chart render, at process boot, and at runtime.
   No `.enabled: false` toggles, graceful-nil branches, silent env fallbacks,
   `failurePolicy: Ignore`, or `--dev-mode` flags. CI enforces (see §10).
10. **Open-core API boundary** (§11). There is ONE public API surface:
    the Apache `sdk` (component-dev protos only — agent / tool / plugin /
    component). It ships zero admin RPCs and zero infra deps and must not
    import the daemon (`make check-no-gibson`). Admin / operator / billing
    protos are daemon-local inside the ELv2 `gibson` monorepo (under
    `internal/server/daemon/api/gibson/<pkg>/v1`), not a separate module.
    The former `platform-sdk` and `platform-clients` repos are retired:
    their protos and shared Go primitives (transport, secrets, readiness,
    pools, observability, authz wrapper) now live in-module in `gibson`
    (`internal/infra/*`). No more cross-module BSR proto sharing between
    those modules.

---

## 1. Before you start

### 1a. If the user is reporting a bug or asking for a fix — search the tracker first

This step gates everything below. When the user describes a defect,
regression, infra gap, broken flow, missing feature, or framing like "X
doesn't work" / "fix Y" / "why is Z failing", BEFORE you read code,
sketch a fix, dispatch a subagent, or file a new issue, run a tracker
search across **both open AND closed** issues.

```bash
# Repo-scoped (most common — pick the repo the symptom most likely lives in):
gh issue list -R zeroroot-ai/<repo> --state all --search "<keywords>" --limit 25

# Cross-repo (use when the symptom could span repos — auth chain, signup
# flow, gitops sync, ESO behaviour, etc.):
gh search issues "org:zeroroot-ai <keywords>" --state all --limit 25
```

Choose keywords from the user's own phrasing first, then add error
message strings, resource names, and file paths. `gh search` hits
title+body but not comments, so vary terms across runs.

Three outcomes drive what happens next:

1. **An open issue matches.** Link it in your reply, continue from THAT
   issue's existing diagnosis, prior comments, and any linked PRs.
   Don't re-discover what's already documented.
2. **A closed issue matches but the user's new evidence shows it's
   actually still broken.** This is the most common driver of repeat
   reports — closed-in-error is real.
   ```bash
   gh issue reopen <n> --comment "Repro 2026-MM-DD: <command>; got <new evidence>"
   ```
   Link the reopened issue, work from there.
3. **No match.** File via the `/to-issues` skill (see §6 wording for the
   shape), link the new issue in the reply, then begin work.

Never start fresh code work on something a prior agent already filed:
duplicate state, lost diagnosis, risk of re-landing a fix that didn't
actually work.

This rule does NOT apply to pure questions ("how does X work"),
navigation ("show me Y"), or one-shot commands ("run Z") — only to
anything that looks like a defect or feature request.

### 1b. What else is in flight?

Run, in this order:

```bash
# What's already in flight under your name?
for repo in gibson sdk dashboard deploy gitops billing \
            setec adk gibson-executor; do
  gh pr list -R zeroroot-ai/$repo --state open \
    --search "author:@me OR assignee:@me" --json number,title,headRefName
done

# What epics are open?
gh project list --owner zeroroot-ai --format json \
  | jq '.projects[] | select(.title | startswith("Epic:")) | {number, title}'
```

If you are joining a named epic, view its board first:

```bash
gh project view <num> --owner zeroroot-ai
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
gh project item-add <project-num> --owner zeroroot-ai --url <pr-url>
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
# In gibson (enterprise/platform/gibson):
make authz-registry && make proto

# In dashboard:
pnpm proto:generate
```

### Agent merge autonomy

Codified in [ADR-0007](https://github.com/zeroroot-ai/docs/blob/main/adr/0007-agent-merge-autonomy.md).
Read the ADR for the reasoning; this section is the operational contract.

**Agents merge their own PRs once every required CI check is `success`.** This
holds across all repos in the org and all commit types — including `feat:`,
`feat!:`, and `BREAKING CHANGE`. The CI rulesets — `pr-title-lint`,
`no-monorepo-shortcuts`, and per-repo required checks — are the merge gate.
They are sufficient. **No repo requires a CODEOWNERS review, a human approval,
or signed commits** — agents self-merge everywhere, including `sdk`, `deploy`,
and `gitops`.

| # | Condition |
|---|-----------|
| 1 | Every required status check is `success` (not `pending`, not `neutral`, not skipped). Verify with `gh pr checks <num>`. |
| 2 | No unresolved review threads (the `tier-core` ruleset already blocks otherwise; check first to avoid the wasted merge call). |
| 3 | Branch is rebased onto the current `origin/main` (no "out of date" warning in the PR). |

When all three hold, merge with:

```bash
gh pr merge <pr-number> --squash --delete-branch
```

`--delete-branch` is **mandatory** — it deletes the remote branch as part of
the merge call. Every repo also has `delete_branch_on_merge=true` set at the
repo level (so human-clicked merges clean up too), but agents pass the flag
explicitly so the cleanup is observable in the gh output and survives any
future repo-setting drift.

After the merge call returns, clean up locally:

```bash
git checkout main
git fetch --prune origin
git branch -D <merged-branch>
```

`fetch --prune` removes the local tracking ref for the deleted remote branch;
`branch -D` removes the local branch itself. Skip neither — leftover local
branches are how agents end up trying to push to a branch that no longer
exists upstream and getting confused by the resulting `--force-with-lease`
failure.

When the gate isn't met, leave the PR for a human and move on to the next
task in your queue. Do not "encourage" the merge with comments or pings.

### Credits-exhausted exception

If GitHub Actions runners are not starting because the org's Actions billing
limit is hit (jobs stay queued indefinitely, or you see a "You have exceeded
your included minutes" error in the run log), **do not stop work.** Follow
this procedure instead:

1. **Confirm it is a credits problem**, not a real failure. Look for: jobs
   stuck in `queued` state with no logs, a billing error in the Actions UI,
   or `gh run list` showing every recent run as `queued` or `cancelled` with
   zero log output.
2. **Run the repo's standard local test suite:**
   ```bash
   # Go repos
   make test          # or: go test -race ./...
   make check         # lint / static analysis if present

   # Dashboard
   pnpm typecheck && pnpm lint && pnpm test

   # Operators
   make test && make manifests
   ```
   Use the per-repo commands in the workspace `CLAUDE.md` "Common per-repo
   commands" section as the authoritative list.
3. **If local tests pass, merge normally** (`gh pr merge <n> --squash --delete-branch`).
   Add a note to the PR body: `CI skipped: GitHub Actions credits exhausted; local tests passed.`
4. **Continue work.** Credits exhaustion does not block PRs, does not block
   new branches, and does not require a halt-and-alert. Keep shipping.
5. **Do NOT file a `ci-failure` issue for the credits condition** — the
   billing situation is not a code defect. If credits are exhausted for an
   extended period (>1 session), mention it in conversation but do not block
   on it.

**Full pre-merge checklist:** the four conditions above are the mechanical part; the complete canonical list (walker gates, CodeQL findings, coverage delta, ADR + trap obligations, escape-hatch ban, `Docs-PR:` trailer) lives at [`docs/agents/pr-checklist.md`](https://github.com/zeroroot-ai/docs/blob/main/agents/pr-checklist.md) in the workspace docs repo. Single source of truth — do not restate items here.


### Agent judgment is the one remaining filter

Beyond CI, the only thing standing between green and merged is the agent's own
judgment that the PR needs a human decision. "I would feel better if a human
looked at this" is not a blocker. "I need a decision I am not authorized to
make" — a design ambiguity, a security-sensitive policy choice, an irreversible
action with multiple defensible answers — is.

When the agent decides a PR (or any in-flight task) genuinely needs a human
decision:

1. **Surface the blocker at the very top of the terminal reply**, before any
   other content, in this shape:

   ```
   === AGENT BLOCKED — DECISION REQUIRED ===
   What is blocked: <one sentence>
   Decision needed: <the specific question>
   Options:
     A) <option> — <tradeoff>
     B) <option> — <tradeoff>
     C) <option> — <tradeoff>
   Artifact: <PR url | branch | spec path>
   ==========================================
   ```

2. **Stop the turn.** Do not schedule a wake-up, do not arm a background
   monitor, do not run a polling loop, do not "check back in N minutes" on a
   human reply. The conversation resumes when the user answers in-band.

Polling for human-typed answers or human-clicked merge buttons is forbidden.
Background monitors and scheduled wake-ups remain correct for log streams,
K8s state changes, and CI runs in progress — none of which are "waiting for a
human." If the work in flight is "waiting for the user to reply," the right
action is always: end the turn.

The judgment call is yours. Calibrate from feedback: surfacing too many
blockers retrains the user to ignore them; surfacing too few makes silent
wrong decisions.

---

## 6. CI failures: triage, file an issue, then fix

When a required check fails on your PR (or on `main` after merge):

1. **Do not blindly rerun** the workflow. The `ci-failure-triage` workflow
   (a `workflow_run` listener wired in each repo, calling the reusable workflow
   at `zeroroot-ai/.github/.github/workflows/ci-failure-triage.yml`) opens or
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
   - **Credits exhausted** (jobs stuck in `queued` with no logs, billing limit
     hit) — this is **not** a CI failure. Do not file a `ci-failure` issue.
     Switch to the local-test path described in §5 "Credits-exhausted
     exception" and keep working.
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

**Remote branch cleanup** happens via two mechanisms (belt and suspenders):

1. Every repo has the GitHub setting `delete_branch_on_merge=true`, so any
   merge — yours, a human's, the SDK fan-out App's — deletes the remote
   branch as the merge completes. (This is a *repo setting*, not a branch
   ruleset rule. The `tier-core` ruleset's `deletion` rule blocks deletion
   of the protected `main` branch; it does **not** auto-delete merged
   feature branches.)
2. Agent self-merges pass `--delete-branch` to `gh pr merge` explicitly
   (see §5), so the cleanup is visible in the command output and survives
   any future repo-setting drift.

**Local cleanup is your responsibility** — the GitHub side does nothing for
your working clone. After every merge (yours or someone else's that you
were following), run:

```bash
git checkout main
git fetch --prune origin
git branch -D <merged-branch>
```

`--prune` removes the dangling local tracking ref (`origin/<branch>`) for the
deleted remote; `branch -D` removes the local branch. If you skip the prune,
the next `git push` from a stale branch will produce a confusing
`--force-with-lease` failure against a ref that no longer exists.

**Audit your local clone** at the start of any session if you've been away —
this one-liner lists local branches whose upstream is gone:

```bash
git fetch --prune origin
git branch -vv | awk '/: gone]/ {print $1}'
```

Delete them with `git branch -D` (they're already merged from `main`'s
perspective, otherwise the remote wouldn't have been deleted).

**Project board automation:** the board's "PR merged → Done" automation
flips the item state. **Do not** edit the board manually.

One fan-out runs after release-please tags the public `sdk`. It fires on
the `opensource/sdk` `v*` tag and bumps the Go consumers that depend on
the public component-dev SDK: `gibson`, `adk` CLI, and `gibson-executor`.
PRs auto-merge if their CI passes. See §9 for the topology.

The former `platform-sdk` and `platform-clients` fan-outs no longer exist:
those repos were retired (ADR-0053) and their protos / Go primitives now
live in-module in `gibson`, so a daemon proto change is just a normal
`gibson` PR — no external consumer bump.

Wait for the SDK fan-out PRs to appear before starting downstream work in
those consumers; landing both a fan-out PR and an unrelated feature branch
on the same consumer in the same window causes avoidable rebase churn.

---

## 8. Cross-repo epics

Anything spanning ≥2 repos is an epic. Each epic gets:

1. **A Project (v2) board** at the org level: `gh project create --owner zeroroot-ai --title "Epic: <id>"`
2. **A consistent branch name** across every repo: `epic/<id>-<slug>` (or just `epic/<id>` if no slug needed).
3. **Items**: every PR added via `gh project item-add`.

The Project board is the single source of truth for "what is in flight." Use
it instead of grepping branches across 12 directories.

**Do not rely on a hardcoded epic list here — it goes stale.** Query the live
set instead (the §1b commands): `gh project list --owner zeroroot-ai` for the
boards, and `gh search prs "org:zeroroot-ai" --state open --head "epic/<id>"`
to see which epic branches still have open work.

---

## 9. Releases

You do **not** cut releases by hand. release-please runs on every push to
`main` in every repo. It opens an auto-generated "release PR" that bumps the
version + writes the CHANGELOG. When a human merges the release PR, the tag
is created automatically and the per-repo image-build workflow fires.

**Only the public `sdk` triggers a fan-out** on tag-publish. The
component-dev protos are the one cross-module surface; everything else is
in-module in `gibson` and needs no consumer bump.

| Foundation module | Repo | Fan-out workflow | Consumer set |
|-------------------|------|------------------|--------------|
| Component-dev SDK | `opensource/sdk` | `sdk/.github/workflows/fan-out.yml` (GitHub App `zeroday-sdk-fanout`) | `gibson`, `adk`, `gibson-executor` |

The fan-out opens `chore(deps): bump sdk to vX.Y.Z` PRs in its consumer
set. Those PRs auto-merge if their CI passes. A summary issue is filed in
the SDK listing all outcomes.

Because admin / operator / billing protos and the shared Go primitives are
now daemon-local in `gibson` (`internal/server/daemon/api/...`,
`internal/infra/...`), a change that used to span `platform-sdk` +
`platform-clients` is now a single `gibson` PR — no inter-module
sequencing, no waiting on a tag.

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
2. Get explicit sign-off from the repo owner. Async is fine; the explicit
   approval is the gate (this is a process agreement, not a ruleset-enforced
   review — no repo requires CODEOWNERS approval).
3. In the same PR that cuts 1.0: remove `"bump-minor-pre-major": true`
   from that repo's `release-please-config.json`, write a commit body that
   names the stability claim, merge.
4. release-please's next cycle proposes `1.0.0` from the accumulated
   commit history; that release PR gets the same owner sign-off before merge.

Reviewers should reject any PR titled with a `1.0.0` or `2.0.0` (etc.)
bump unless the proposing issue exists and was approved.

Historical context: on 2026-05-17 a `feat!:` PR on `opensource/sdk` reflexively
crossed the polyrepo from 1.9.0 to 2.0.0, then bricked the SDK fan-out
because Go's v2+ module-path rule requires `/v2` and the SDK doesn't have
it. Recovery: full polyrepo reset back to 0.x (PRD
zeroroot-ai/.github#25). The `bump-minor-pre-major` setting is the only
structural change that prevents repeat.

---

## 10. Hard prohibitions (CI-enforced where possible)

- **No `go.work`** at any repo root. Cross-module changes go through SDK tag → consumer bump.
- **No `replace` directives** in `go.mod`.
- **No git submodules.**
- **No `--no-verify`** on commits.
- **No `--force-push` to main** (rejected by ruleset).
- **No direct push to main** (rejected by ruleset).
- **No rerunning a failed CI job without first posting a root-cause comment**
  on the `ci-failure` issue the triage workflow opened (see §6).
- **The public `sdk` must not import the daemon — `make check-no-gibson`.**
  The Apache `sdk` is the component-dev surface only; its `go.mod` must not
  pull `github.com/zeroroot-ai/gibson` (mechanical grep in the SDK Makefile,
  required in CI). Admin / operator / billing protos and the shared Go
  primitives are daemon-local in the `gibson` monorepo now (ADR-0053), so
  there is no cross-module proto sharing to police between separate
  foundation modules. Within `gibson`, platform protos live under
  `internal/server/daemon/api/gibson/<pkg>/v1` — plain in-module includes,
  no BSR dep, no M-mapped `go_package`, no vendored `.proto`.
- **No admin / operator / billing protos in the public `sdk`.** The Apache
  SDK ships only the component-dev surface — agent / tool / plugin /
  component / harness / mission protos (ADR-0058). What must NOT appear in
  `opensource/sdk/api/proto/` is the platform surface that now lives
  daemon-local in `gibson`: tenant administration (`gibson.tenant.v1.*` —
  Tenant/Membership/Grants/Provider/Secrets/User/Usage/Budget/ModelAccess),
  the operator surface (`gibson.daemon.operator.v1`), billing, discovery,
  plus any secret-bearing internal message type. Billing has no proto in
  the SDK at all — it is a CLOSED `billing` repo injected through gibson's
  `pkg/billing` / `internal/billing` seam. Reintroducing any of those
  packages under the SDK is rejected by review.
- **No infra-client deps in `opensource/sdk/go.mod`.** The CodeQL deny-list
  query (in `zeroroot-ai/codeql-go-queries`) fails CI when the SDK's module
  graph pulls Vault / OpenBao / AWS Secrets Manager / GCP Secret Manager /
  Azure Key Vault / SPIFFE / Redis / Neo4j / OpenFGA admin / pgx / any other
  first-party-internal infra client. Those clients now live in `gibson`'s
  `internal/infra/*` (ex `platform-clients`) and are consumed only inside
  the gibson module. Smoke check: `go mod why` from a clean SDK consumer
  returns nothing for any of those modules. Adding such a dep on the SDK is
  a fundamental category error; the work belongs in `gibson/internal/infra`.
- **One code path — see [ADR-0003](https://github.com/zeroroot-ai/docs/blob/main/adr/0003-one-code-path.md).**
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

## 11. Open-core API surface and required CI checks per repo type

The open-core re-architecture (ADRs 0050–0058) collapsed the old
three-module split into a licensing-driven topology. There is now ONE
public API surface — the Apache `sdk` — and everything else is in-module
inside the ELv2 `gibson` monorepo. Knowing which repo and which license
tier you are editing decides which checks must be green before merge.

### Licensing tiers and where things live

| Tier | Repos | Role |
|------|-------|------|
| Apache-2.0 (build + run components) | `sdk`, `python-sdk`, `adk`, `setec`, `gibson-executor` | Customer / community surface. `sdk` = component-dev protos ONLY (agent / tool / plugin / component / harness / mission). |
| Elastic License v2 (operate the platform) | `gibson` (monorepo), `dashboard`, `deploy` | `gibson` absorbed the former `ext-authz` (`cmd/ext-authz`), `tenant-operator` (`operators/tenant`), `platform-operator` (`operators/platform`), `spiffe-jwks-exporter` (`cmd/spiffe-jwks-exporter`), `platform-clients` (`internal/infra/*`), and the `platform-sdk` admin protos (daemon-local under `internal/server/daemon/api/gibson/<pkg>/v1`). |
| Closed (commercial) | `billing` | Stripe backend, injected into `gibson` through the `pkg/billing` / `internal/billing` seam; on-prem links a no-op bypass. |
| Private (not distributed) | `gitops` | ZeroRoot Cloud ops. |

The single public API module is `sdk`. Admin / operator / billing /
discovery protos are daemon-local in `gibson` — not a separate module, no
BSR cross-module dep. The shared Go primitives (transport, secrets,
readiness, pools, observability, authz wrapper) that used to live in
`platform-clients` are now `gibson/internal/infra/*`, consumed only inside
the gibson module. `platform-sdk` and `platform-clients` are retired and
deleted (ADR-0053); `gibson-tool-runner` was renamed `gibson-executor`.

The boundary that matters: the `sdk` must not import `gibson`
(`make check-no-gibson`) and must carry zero infra deps; everything
platform-side is internal to `gibson`.

### Required CI checks per repo type

The checks below are the ones specific to the open-core boundary. Per-repo
rulesets layer additional repo-specific required checks on top (see
`gh ruleset list --org zeroroot-ai`).

| Check | Public SDK (`opensource/sdk`) | `gibson` monorepo (ELv2) | Other Apache repos (`adk`, `setec`, `gibson-executor`) |
|-------|-------------------------------|--------------------------|--------------------------------------------------------|
| `buf breaking` against last published BSR tag (`WIRE_JSON`) | required | — | — |
| `make check-no-gibson` (SDK go.mod must not depend on the daemon) | required | — | — |
| CodeQL deny-list (no infra deps in `go.mod`) | required | — | — |
| Dependency-graph size smoke (bounded transitive module count from an empty consumer) | required | — | — |
| Reproducible-build hash compare (two independent runners) | required | required | required |
| Contract tests (round-trip one RPC per service against testcontainer FGA/Neo4j/Redis) | — | required | — |

The reusable workflows for all of these live in this org `.github` repo
under `.github/workflows/` and are called from each consumer repo. Tool
versions are pinned by full semver or SHA — never `latest`, never
major-only — so workflow drift does not produce per-PR build differences.

### Cross-link to ADRs

The open-core boundary is tracked in the `zeroroot-ai/docs` ADR series and
the migration map at `architecture/open-core/MIGRATION-MAP.md`:

- [ADR-0050](https://github.com/zeroroot-ai/docs/blob/main/adr/0050-open-core-boundary.md) — Open-core licensing boundary (Apache vs ELv2 vs closed vs private)
- [ADR-0053](https://github.com/zeroroot-ai/docs/blob/main/adr/0053-retire-platform-sdk-and-clients.md) — Retire `platform-sdk` and `platform-clients`; fold into the `gibson` monorepo
- [ADR-0056](https://github.com/zeroroot-ai/docs/blob/main/adr/0056-repo-topology-consolidation.md) — Repo-topology consolidation (operators, ext-authz, spiffe-jwks-exporter into `gibson`)
- [ADR-0058](https://github.com/zeroroot-ai/docs/blob/main/adr/0058-sdk-scope-component-dev-surface.md) — The public SDK is the component-dev surface only (admin protos move daemon-local)

These supersede the former two-surface contract (ADR-0025/0026/0028) and
its refinements (ADR-0037/0039/0040), which described the now-retired
`platform-sdk` / `platform-clients` split.

---

## 12. When in doubt

- Read the per-repo `CLAUDE.md`. It overrides this file when explicitly noted.
- Check `gh ruleset list --org zeroroot-ai` to see what's actually enforced.
- Open a PR (ready-for-review, not draft) early and let CI tell you what's wrong.
- If a ruleset blocks something legitimate, ask the operator — they have
  bypass during the soft-launch period; tightening happens after the rules
  prove themselves.
- If a `ci-failure` issue is open against a workflow you're about to touch,
  read the latest comment first — the previous agent's diagnosis usually saves
  you a re-debug.
