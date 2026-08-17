# The launch scorecard

## Why it exists

Between 2026-08-13 and 2026-08-17 the fleet merged about 570 commits, filed 455
issues and closed 425. Zero of the six launch chains passed its exit test.

Nothing in the system measured that. Every signal available to an agent —
"the PR merged", "the issue closed", "CI is green" — reported success while the
product did not move. The estate was torn down on 2026-08-16, which removed the
last thing that could contradict a false success.

The scorecard is the missing signal. It measures **outcomes**, and it measures
**whether the fleet is spending effort on outcomes**.

## The GitHub features it uses, and why

| Need | Feature | Why this one |
|---|---|---|
| Outcome per chain | **Workflow runs** with a fixed file name per chain | A green run is objective. Self-reported status is not. `gh run list --workflow` returns the conclusion in one call |
| The board itself | **A pinned Issue** in `zeroroot-ai/.github` | An agent reads the whole board in ONE cheap command. The human sees it at the top of the tracker. Edit history preserves every past version |
| The writer | **A scheduled Action** (`launch-scorecard.yml`) | Runs daily at 06:00 UTC and on demand. Nobody has to remember |
| Behaviour metrics | **Search API `total_count`** | One call per metric, org-wide, counts private repos when the token can see them |
| Trend | **A history block inside the issue body** | No external store. Survives a rewrite. Lets the renderer detect a stall |

### Rejected, and why

- **Projects v2 boards** — needs GraphQL to read, holds no time series, and its
  built-in progress is *issue closure*, which is exactly the metric that failed.
  Boards stay for cross-repo epics; they are not the scorecard.
- **Milestones** — progress equals closed issues. Same failure.
- **Repository custom properties** — static metadata, no history.
- **A dashboard outside GitHub** — an agent cannot read it at session start
  without extra credentials.

## How an agent uses it

At the start of every session:

```bash
gh issue list -R zeroroot-ai/.github --state open \
  --search 'in:title "LAUNCH SCORECARD"' --json body --jq '.[0].body'
```

The body opens with an `AGENT DIRECTIVES` block. Those are orders. They override
the priorities in the workspace `CLAUDE.md`. Examples:

- *Work chain 1 only* — when a lower-numbered chain is not passing.
- *Chains 2, 3 have no exit-test workflow* — building it IS the first task.
- *STALL: 3 days with no chain flip. HALT.* — post the halt banner and stop.
- *File nothing this session* — when issue filing is over budget.
- *Your next PR must touch product paths* — when hygiene work is over budget.

The machine-readable block at the bottom carries the same facts as JSON, for any
tool that wants to parse rather than read.

## The thresholds, and what each one catches

| Metric | Limit | The failure it catches |
|---|---|---|
| Chain flips | 1 per 2 days | The stall. Four days of high output and no movement |
| Issues filed | 35 per 7 days | The issue farm. 455 filed in 4 days, 264 of them scanner alerts |
| Hygiene share of merged PRs | 20% | CI-about-CI. 25% of `deploy` PRs touched only `.github/` and `scripts/` |
| Rework share of merged PRs | 10% | Guards that need re-pinning, fixes of fixes |
| Open `ci(codeql)` issues | 5 | The tracker used as an alert queue |
| Open PRs per repo | 3 | Fan-out with no landing |

Tune a limit by editing the `MAX_*` defaults at the top of
`scripts/launch-scorecard.sh`. Do not raise a limit to silence a directive.

## Adding or changing a chain

Edit `data/launch-chains.tsv`. One tab-separated row per chain:

```
n	name	repo	workflow	root_issue	exit_test
```

The workflow must exist in that repo and must run **without staging or prod** —
kind, `terraform plan`, a rendered chart, or a fake sink. A test that needs a
live cluster can never go green while the estate is down, so it is not a valid
exit test.

## Local use

```bash
scripts/launch-scorecard.sh collect > /tmp/sc.json   # needs org read
scripts/launch-scorecard.sh render  < /tmp/sc.json   # no network
bash scripts/test-launch-scorecard.sh                # fixtures, no network
```

`collect` fails loudly if the token cannot see private repos. A partial
scorecard is not allowed: it would under-report and read as green.
