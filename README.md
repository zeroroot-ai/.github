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
| `actions/*/` | Composite actions the reusable workflows call. Each one carries its scanner and its self-test |
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

## Tree guards

Two guards read the calling repository's tree. Every repo runs both, from one
caller workflow.

| Guard | What it rejects | Config |
|---|---|---|
| `brand-guard` | A retired brand string anywhere in the tracked tree | [`actions/brand-guard/check-brand.sh`](actions/brand-guard/check-brand.sh) |
| `link-check` | A broken link in any Markdown file, including a relative path and an anchor | [`actions/link-check/lychee.toml`](actions/link-check/lychee.toml) |

Copy [`templates/tree-guards.yml`](templates/tree-guards.yml) to
`.github/workflows/tree-guards.yml` in the repo. It has two jobs and needs no
secret. A repo with a merge queue keeps the `merge_group` trigger, because a
required check that never runs in the queue lane stalls the queue.

Each guard takes its exceptions from one file at the repo root, and each file
is keyed by content:

- `.brand-guard-allow` lists repo-relative paths. Every path needs a `# why:`
  comment on the line above it. An entry that no longer matches anything fails
  the guard, so the list shrinks.
- `.lychee.toml` adds to the org link policy. lychee merges the configuration
  files, and list keys append, so the caller file never drops an org exclusion.

A single line may also carry the marker `brand-guard-exempt:` with a reason. Use
it for a test that asserts a retired string is absent, because that test has to
contain the string.

This repo runs both guards on itself, and runs their failing fixtures, in
[`.github/workflows/tree-guards.yml`](.github/workflows/tree-guards.yml).

## Consuming a reusable workflow

Pin by SHA **and name the release in a trailing comment**:

```yaml
uses: zeroroot-ai/.github/.github/workflows/reusable-go-ci.yml@<sha> # v1.2.3
```

Both halves matter, and the second one is not decoration.

The SHA is what actually runs, and it is immutable: a branch ref would mean
whoever moves `main` here controls what runs in every repo in the org.

The comment is what lets a machine bump it. Dependabot's github-actions updater
resolves a pinned SHA **against this repo's tags**. That is the same mechanism
it uses for `actions/checkout` and `github/codeql-action`, and it is why those
get bumped automatically everywhere.

This repo publishes tags through
[release-please](.github/workflows/release-please.yml), so Conventional Commit
titles here become releases, and releases become Dependabot pull requests in
every consumer.

### Verifying a release

`reusable-verify-release.yml` is the release policy. Call it after the build
with the image, your own repo and the commit:

```yaml
verify:
  needs: image
  uses: zeroroot-ai/.github/.github/workflows/reusable-verify-release.yml@<sha> # vX.Y.Z
  with:
    image_ref: ghcr.io/zeroroot-ai/<name>@${{ needs.image.outputs.digest }}
    expected_subject_repo: ${{ github.repository }}
    expected_commit_sha: ${{ github.sha }}
```

The shared build signs with its own identity, not yours. The policy binds your
repo and commit through the certificate's workflow-repository and workflow-SHA
extensions. It then checks the buildx provenance inside the signed index, and
verifies the SBOM attestation by its RFC 3161 timestamp, because the build
writes no Rekor entry for it.

### Why this is spelled out

Until 2026-09-16 this repo had **no tags at all**. The pins were correct and
immutable, and nothing could ever bump them: 113 Dependabot pull requests across
six consumer repos, and not one had ever touched a `zeroroot-ai/.github` ref.
Dependabot was not broken — there was simply no newer version for it to name.

The cost landed on people. Every shared fix needed a hand-written seven-repo
fan-out, and on one day four of them meant 28 mechanical pull requests. Two
shipped wrong: a guard merged while every consumer pin still pointed at the
commit before it, and a broken workflow that seven repos then had to be walked
off one at a time.

A pin nothing can bump is not a supply-chain control. It is a manual process
wearing one's clothes.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [AGENTS.md](AGENTS.md).
Security issues: [SECURITY.md](SECURITY.md).

## License and history

Apache License 2.0. See [LICENSE](LICENSE). Copyright Zero Root AI.

Issue and pull request numbers cited in comments and documents dated before 2026-09-05 refer to the tracker before the history reset, archived offline. They do not resolve on GitHub.
