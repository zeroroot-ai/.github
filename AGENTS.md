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
10. **Two-surface platform contract** (§11). `opensource/sdk` is the
    customer-facing API client and ships zero admin RPCs and zero infra
    deps. Every internal proto lives in `enterprise/platform/platform-sdk`;
    every shared Go primitive (transport, secrets, readiness, pools,
    observability, authz wrapper) lives in
    `enterprise/platform/platform-clients`. Cross-module proto sharing
    goes through BSR — never vendored `.proto`, never M-mapped
    `go_package`.

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
for repo in gibson sdk platform-sdk platform-clients ext-authz dashboard \
            tenant-operator platform-operator deploy gitops debug-plugin \
            setec adk gibson-tool-runner spiffe-jwks-exporter; do
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
# In core/gibson:
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
`no-monorepo-shortcuts`, per-repo required checks, and the
`tier-platform-release` signed-commits + CODEOWNERS-review ruleset on `sdk`,
`deploy`, `gitops` — are the merge gate. They are sufficient.

| # | Condition |
|---|-----------|
| 1 | Every required status check is `success` (not `pending`, not `neutral`, not skipped). Verify with `gh pr checks <num>`. |
| 2 | No unresolved review threads (the `tier-core` ruleset already blocks otherwise; check first to avoid the wasted merge call). |
| 3 | Branch is rebased onto the current `origin/main` (no "out of date" warning in the PR). |
| 4 | On `tier-platform-release` repos (`sdk` / `deploy` / `gitops`): the required CODEOWNERS review has been submitted as approve. That review *is* the human checkpoint for these repos; the merge button is not a second checkpoint. |

When all four hold, merge with:

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

Three independent fan-outs run after release-please tags one of the
foundation modules. Each is a separate workflow firing on its own repo's
`v*` tag; the consumer set differs:

- **`opensource/sdk` tag** (customer-facing client SDK) → fans out to the
  Go consumers that still depend on the public SDK: `gibson`, `adk` CLI,
  `gibson-tool-runner`, `debug-plugin`, plus any external example repos.
  PRs auto-merge if their CI passes. See §9 for the topology.
- **`enterprise/platform/platform-sdk` tag** (internal protos: admin,
  platform-operator, tenant-admin, budget, usage, authz, discovery,
  DaemonAdminService) → fans out to internal consumers: `gibson`,
  `ext-authz`, `tenant-operator`, `platform-operator`,
  `spiffe-jwks-exporter`, `dashboard` (TypeScript regen).
- **`enterprise/platform/platform-clients` tag** (shared Go library:
  transport / secrets / readiness / pools / observability / authz) →
  fans out to every internal Go service: `gibson`, `ext-authz`,
  `tenant-operator`, `platform-operator`, `spiffe-jwks-exporter`,
  `gibson-tool-runner`.

Wait for the relevant fan-out PRs to appear before starting downstream
work in those consumers; landing both a fan-out PR and an unrelated
feature branch on the same consumer in the same window causes avoidable
rebase churn.

---

## 8. Cross-repo epics

Anything spanning ≥2 repos is an epic. Each epic gets:

1. **A Project (v2) board** at the org level: `gh project create --owner zeroroot-ai --title "Epic: <id>"`
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

**Three foundation modules each trigger their own fan-out** on tag-publish.
The consumer sets are distinct; do not assume one fan-out's PR opening
implies another will:

| Foundation module | Repo | Fan-out workflow | Consumer set |
|-------------------|------|------------------|--------------|
| Customer-facing SDK | `opensource/sdk` | `sdk/.github/workflows/fan-out.yml` (GitHub App `zeroday-sdk-fanout`) | `gibson`, `adk`, `gibson-tool-runner`, `debug-plugin` (+ external examples) |
| Internal protos | `enterprise/platform/platform-sdk` | `platform-sdk/.github/workflows/fan-out.yml` | `gibson`, `ext-authz`, `tenant-operator`, `platform-operator`, `spiffe-jwks-exporter`, `dashboard` (TS regen) |
| Shared Go library | `enterprise/platform/platform-clients` | `platform-clients/.github/workflows/fan-out.yml` | `gibson`, `ext-authz`, `tenant-operator`, `platform-operator`, `spiffe-jwks-exporter`, `gibson-tool-runner` |

Each fan-out opens `chore(deps): bump <module> to vX.Y.Z` PRs in its
consumer set. Those PRs auto-merge if their CI passes. A summary issue is
filed in the source module listing all outcomes.

A change that touches both an internal proto AND a shared-library helper
that wraps it should be sequenced: land the `platform-sdk` PR first, let
fan-out land in `platform-clients`, then land the `platform-clients` PR
that consumes the new proto. Reversing the order leaves the wrapper
referring to a proto type that does not yet exist in any tagged module.

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
- **No `--no-gpg-sign`** (signed commits required by ruleset on production-tier repos).
- **No rerunning a failed CI job without first posting a root-cause comment**
  on the `ci-failure` issue the triage workflow opened (see §6).
- **No local proto includes — cross-module proto sharing goes through BSR.**
  Proto reuse between any two of the three foundation modules (`opensource/sdk`,
  `platform-sdk`, `platform-clients`) MUST go through BSR module deps:
  `buf.build/zeroroot-ai-platform/<module>` declared in `buf.yaml` `deps:`,
  pinned by `buf.lock`. Never vendor `.proto` files (no `cp` of one module's
  proto into another's tree). Never M-map `go_package` via
  `buf.gen.yaml managed.override.file_option`. Never duplicate a proto type
  across modules. If a shared type does not yet exist as a separate package,
  extract it to its own package in the module that owns it and depend via
  BSR. Reviewers should grep new PRs for vendored `.proto` files and M-map
  overrides and reject if present.
- **No admin / infra protos in `opensource/sdk`.** The customer-facing OSS
  SDK is a stripe-go-like API client and ships only what 3rd-party
  agent/tool/plugin authors and customer integrations need to call. Every
  admin RPC, every secret-bearing message type, every platform-operator /
  tenant-admin / authz-admin / discovery / DaemonAdminService proto lives
  in `enterprise/platform/platform-sdk` and nowhere else. Reintroducing a
  `gibson.admin.v1` / `gibson.usage.v1` / `gibson.authz.v1` /
  `gibson.daemon.discovery.v1` / `gibson.platform.v1` / `gibson.tenant.v1`
  directory under `opensource/sdk/api/proto/` is rejected by review.
- **No infra-client deps in `opensource/sdk/go.mod`.** The CodeQL deny-list
  query (in `zeroroot-ai/codeql-go-queries`) fails CI when the OSS SDK's
  module graph pulls Vault / OpenBao / AWS Secrets Manager / GCP Secret
  Manager / Azure Key Vault / SPIFFE / Redis / Neo4j / OpenFGA admin /
  pgx / any other first-party-internal infra client. Those clients live
  in `platform-clients` and are consumed only by internal services.
  Smoke check: `go mod why` from a clean SDK consumer returns nothing for
  any of those modules. Adding such a dep on the SDK is a fundamental
  category error; rewrite the work into platform-clients instead.
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

## 11. Two-surface API contract and required CI checks per repo type

The org's Go module graph is intentionally split across three foundation
modules, each with a distinct audience and a distinct CI contract.
Knowing which one you are editing decides which checks must be green
before merge.

### Two-surface model

| Module | Repo | Audience | What lives here |
|--------|------|----------|-----------------|
| Customer-facing SDK | `opensource/sdk` | 3rd-party customers (agent / tool / plugin authors and integrations) | Authoring protos (agent/tool/plugin/component/harness v1) + customer-callable daemon RPCs (member-scoped `DaemonService`, graph, intelligence, identity `WhoAmI`). Customer-facing OAuth2 helper (`auth/oidc/`). Zero admin RPCs, zero infra deps. Released as a customer artifact, semver line independent. |
| Internal protos | `enterprise/platform/platform-sdk` | Internal services (gibson, ext-authz, tenant-operator, platform-operator, spiffe-jwks-exporter, dashboard) | Every admin proto: `DaemonAdminService`, platform-operator service, tenant-admin, authz, usage, discovery, plus any RPC requiring `relation:"admin"` / `relation:"writer"`. Independent BSR module, independent semver. |
| Shared Go library | `enterprise/platform/platform-clients` | Same internal services | Transport (ConnectRPC builders with full interceptor chain), secrets (broker with lease renewal + circuit breaker), readiness (probe aggregator + `/readyz`), pools (Neo4j/Redis/pgx with mandated overrides), observability (OTel + slog + correlation), authz (FGA wrapper + identity-header validation). Consumes `platform-sdk` types; never consumed by `opensource/sdk`. |

Composability comes from narrow public interfaces, not a monorepo. A new
internal service depends on both `platform-sdk` and `platform-clients` at
pinned tags; a customer integration depends on `opensource/sdk` and
nothing else.

### Required CI checks per repo type

The checks below are the ones specific to the platform-contract refactor.
Per-repo rulesets layer additional repo-specific required checks on top
(see `gh ruleset list --org zeroroot-ai`).

| Check | OSS SDK (`opensource/sdk`) | platform-sdk | platform-clients | Internal Go services |
|-------|---------------------------|--------------|------------------|----------------------|
| `buf breaking` against last published BSR tag (`WIRE_JSON`) | required | — | — | — |
| `buf breaking` against last published BSR tag (`FILE`) | — | required | — | — |
| Reproducible-build hash compare (two independent runners) | required | required | required | required |
| CodeQL deny-list (no infra deps in `go.mod`) | required | — | — | — |
| Cross-repo contract tests (round-trip one RPC per service against testcontainer FGA/Neo4j/Redis) | — | required | required | required |
| Dependency-graph size smoke (under 30 transitive modules from an empty consumer) | required | — | — | — |

The reusable workflows for all of these live in this org `.github` repo
under `.github/workflows/` and are called from each consumer repo. Tool
versions are pinned by full semver or SHA — never `latest`, never
major-only — so workflow drift does not produce per-PR build differences.

### Cross-link to ADRs

The architectural decisions behind this contract are tracked in the
`zeroroot-ai/docs` ADR series:

<!-- TODO: replace placeholders with the actual ADR numbers once
zeroroot-ai/.github#101 slice #27 lands the ADR PR on zeroroot-ai/docs.
The 5 ADRs are: two-surface contract; platform-clients mandate;
wholesale-flip discipline; proto hygiene contract (protovalidate +
idempotency_key + pagination + buf breaking); reproducible-CI mandate
(pinned tools + CodeQL deny-list + cross-repo contract tests). -->

- ADR-NNNN — Two-surface platform contract (OSS SDK vs platform-sdk vs platform-clients)
- ADR-NNNN — `platform-clients` shared-library mandate for internal Go services
- ADR-NNNN — Wholesale-flip discipline (no parallel codepaths, no compat shims)
- ADR-NNNN — Proto hygiene contract (`protovalidate`, `idempotency_key`, pagination, `buf breaking`)
- ADR-NNNN — Reproducible-CI mandate (pinned tool versions, CodeQL deny-list, contract tests, reproducible-build hash compare)

If a memory-loaded session shows ADR numbers above as `NNNN`, that means
the docs PR has not landed yet — follow up at `zeroroot-ai/.github#117`
and `zeroroot-ai/.github#101`.

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
