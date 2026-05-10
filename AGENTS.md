# AI agent runbook for `zero-day-ai/*`

This file is the contract every AI agent (Claude Code, opencode, others) reads
before doing any work in this org. It is agent-agnostic; the same rules apply
whether you are a human or an LLM-driven session. Per-repo `CLAUDE.md` files
override only when explicitly noted.

## tl;dr (for agents skimming)

1. **Never push to `main`.** Branch, PR, wait for CI, leave it for a human to merge.
2. **Conventional Commits everywhere.** PR title is the squash-merge subject and
   drives release-please. Malformed title → `pr-title-lint` fails → no merge.
3. **Three branch patterns:** `epic/<id>-<slug>`, `feat/<short>`, `fix/<short>`.
4. **Cross-repo work goes on a Project board** named `Epic: <id>`. Find or create
   the board, add your PRs as items.
5. **Rebase, never merge.** `git fetch origin && git rebase origin/main`.
6. **Squash-merge only**, ruleset-enforced. Multi-commit PRs are fine; the
   squash subject is set from the PR title.
7. **You never merge your own PR.** Merge approval is the only mandatory human gate.

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
gh pr create --draft \
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

**Open as draft** while CI runs. Flip to ready-for-review only after every
required check passes:

```bash
gh pr ready <pr-number>
```

**Add to the epic board** if this PR is part of one:

```bash
gh project item-add <project-num> --owner zero-day-ai --url <pr-url>
```

The board's built-in automation moves the item through `Todo → In Progress →
In Review → Done` based on PR state. Agents do not update the board manually
once the item is added.

**Agents never merge their own PRs.** Wait for a human. Use this idle time
for the next task in your queue, not to "encourage" the merge.

---

## 5. Rebasing & merge strategy

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

---

## 6. After merge

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

## 7. Cross-repo epics

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

## 8. Releases

You do **not** cut releases by hand. release-please runs on every push to
`main` in every repo. It opens an auto-generated "release PR" that bumps the
version + writes the CHANGELOG. When a human merges the release PR, the tag
is created automatically and the per-repo image-build workflow fires.

**SDK releases trigger the fan-out**: when a `core/sdk` tag is published, a
workflow opens `chore(deps): bump sdk to vX.Y.Z` PRs in each of the 6 Go
consumers. Those PRs auto-merge if their CI passes.

If you need an out-of-band release (rare), open an issue first; do not hand-tag.

---

## 9. Hard prohibitions (CI-enforced where possible)

- **No `go.work`** at any repo root. Cross-module changes go through SDK tag → consumer bump.
- **No `replace` directives** in `go.mod`.
- **No git submodules.**
- **No `--no-verify`** on commits.
- **No `--force-push` to main** (rejected by ruleset).
- **No direct push to main** (rejected by ruleset).
- **No merging your own PRs** (convention; humans approve merges).
- **No `--no-gpg-sign`** (signed commits required by ruleset on production-tier repos).

The `no-monorepo-shortcuts` workflow runs as a required check on every PR
across every repo and will fail any PR that introduces `go.work`, `replace`,
or `.gitmodules`.

---

## 10. When in doubt

- Read the per-repo `CLAUDE.md`. It overrides this file when explicitly noted.
- Check `gh ruleset list --org zero-day-ai` to see what's actually enforced.
- Open a draft PR early and let CI tell you what's wrong.
- If a ruleset blocks something legitimate, ask the operator — they have
  bypass during the soft-launch period; tightening happens after the rules
  prove themselves.
