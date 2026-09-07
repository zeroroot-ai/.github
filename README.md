# `.github`

Org-wide GitHub configuration for [zeroroot-ai](https://github.com/zeroroot-ai):
reusable workflows, rulesets, issue and PR templates, and the agent workflow
contract.

**Apache-2.0.** Every other repo in the org consumes the workflows here by
commit SHA, and so can you.

## What is in here

| Path | What |
|---|---|
| `.github/workflows/reusable-*.yml` | Reusable workflows called by every repo — Go CI, image build and sign, release-please |
| `.github/workflows/*.yml` | Org-level jobs: ruleset drift, security-feature drift, doc coverage, the launch scorecard |
| `rulesets/org/*.json` | Branch-protection tiers. **These files are the source of truth**, not the live GitHub state |
| `rulesets/repo/*.json` | Per-repo required checks |
| `data/launch-*.tsv` | What the launch scorecard measures |
| `scripts/` | The guards, each with a mutation test proving it can fail |
| `AGENTS.md` | The branching, PR, release and merge contract |
| `profile/README.md` | The org landing page |

## Rulesets are code

`rulesets/` is authoritative. `apply-rulesets.yml` PUTs every file on merge, and
`ruleset-drift.yml` fails hourly if live GitHub state has diverged.

**A change made in the GitHub UI is not "already applied" — it is pending
deletion.** Edit the JSON and merge it.

## Version links are code

`version-links.yaml` names every version that one repo owns and other repos
copy (a fork's pinned upstream tag, a chart's image tag and pin). The source
is the one place a human edits. `version-drift.yml` compares every link daily,
watches the upstream release feed, and keeps one tracker issue that closes
itself when the links agree (zeroroot-ai/.github#20).

## Guards ship with a failing fixture

Every guard in `scripts/` has a matching `test-*.sh` that mutates its input and
requires the guard to go red. A guard that cannot fail is worse than no guard,
because it gets read as evidence. `ruleset-drift.yml` runs those mutation suites
on every PR, with no secrets, so they gate.

## Consuming a reusable workflow

Pin by SHA, not by tag or branch:

```yaml
uses: zeroroot-ai/.github/.github/workflows/reusable-go-ci.yml@<sha>
```

Dependabot raises bumps for these across the org.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md).
Security issues: [SECURITY.md](SECURITY.md).
