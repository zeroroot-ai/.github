# rulesets/ — the committed source of truth for branch protection

JSON in this directory is what `apply-rulesets.yml` PUTs to GitHub. Live state
is a **cache** of these files, never the authority.

That distinction is the whole point of this README, because it is not how the
GitHub UI presents it. Editing a ruleset live looks permanent and behaves
permanently — until the next push touching *any* `rulesets/**.json` for *any*
repo in the org, at which point the reconciler PUTs the committed file over the
top and the live edit is gone. A live-only change is not "already applied". It
is **pending deletion**.

That is not hypothetical: `gibson-executor`'s `Lint (golangci-lint)` required
check was applied out of band, gibson-executor#369 was closed against it, and
it survived only because nobody happened to edit another repo's ruleset first
(.github#264).

## Rules of engagement

1. **Change the file, then merge.** Never `gh api --method PUT .../rulesets/<id>`
   as the final step. If an emergency live edit is unavoidable (a frozen queue
   at 2am), it is a temporary patch — land the same change in the file the same
   day, or it will be reverted without warning.
2. **`apply-rulesets.yml` verifies itself.** Its `verify-applied` job re-reads
   live state and compares it back to the files, so a green run means "live
   matches", not merely "the API accepted the calls". Several of the apply
   steps only `::warning::` on failure (private-repo plan gates), so without
   that job the workflow could report success having changed nothing.
3. **`ruleset-drift.yml` re-checks hourly**, catching edits made between
   applies. Both jobs run `scripts/check-ruleset-drift.sh`, which is itself
   mutation-tested by `scripts/test-ruleset-drift.sh` on every PR — a drift
   guard that cannot go red is worse than no guard, because its green gets read
   as evidence.

## Required-check contexts: the two traps

A required status check is only a gate if the context can actually be produced,
**and** it is produced on every PR. Two ways to get this wrong, both of which
have bitten this org:

**Trap 1 — a name no workflow emits.** The context is a literal string match
against a check-run name. `tier-opensource` required `Analyze (go)` for over
three months. No repo in that tier has ever produced it: `setec`, `adk` and
`gibson-executor` name the job `Analyze Go` (single-language CodeQL), while
`zerocool-plugins` and `sdk-ts` have no `codeql.yml` at all. The parenthesised
form comes from a *matrix* CodeQL job (`Analyze (${{ matrix.language }})`, as
in `sdk`). It was dead weight that misrepresented what was enforced (.github#261).

It was removed rather than corrected, because no single context name can work
for a tier spanning Go and TypeScript repos. **CodeQL is gated per-repo
instead**, inside that repo's `ci-required` aggregator.

**Trap 2 — a paths-filtered workflow.** A `paths:` filter on a workflow's
`pull_request` trigger produces **zero** check runs on a non-matching PR. The
required context is then *absent* rather than green, and merge-queue entry
freezes for that PR (.github#202, deploy#1509, deploy#1512, deploy#1521). A
job-level `if:` is fine — that reports a *skipped* check run, which satisfies
rulesets. The defect is specifically the trigger-level filter, which suppresses
the run entirely. Do cost control with an in-workflow `changes` job, never with
a trigger filter, on any workflow feeding a required context.

## Prefer one aggregated context per repo

The historical failure mode here was under-specified required sets: a repo runs
fourteen gates and requires three of them, so a gate can exist, run, correctly
report red, and the PR merges anyway (deploy#1526 merged with its own
`validate` job red; gibson-executor#341; gibson-executor#369).

The fix is not a longer list — a list drifts the moment someone adds a gate and
forgets the ruleset, and it can only ever be maintained from a different repo
than the workflows it names. Instead each repo exposes a single **`ci-required`**
aggregator job that `needs:` every gate and fails if any of them failed, and
that one context is what the ruleset requires. New gates are covered by adding
them to `needs:`, in the same PR and the same repo as the gate itself.

Aggregator semantics that must hold (see any repo's `ci-required` job):

- `if: always()`, because a `needs:` job is skipped when *any* dependency is
  skipped — without it the aggregator vanishes exactly when a gate was skipped.
- `skipped` and `success` count as pass; `failure` and `cancelled` count as
  fail. Skipped-for-paths is a legitimate pass; skipped-because-upstream-broke
  is not, and that is why upstream `changes`-style jobs must never be
  lane-restricted (gibson#1368).
- It must enumerate `needs.<job>.result` **explicitly**. `always()` plus no
  evaluation is a job that passes whenever it runs, i.e. a guard that cannot
  fail.
