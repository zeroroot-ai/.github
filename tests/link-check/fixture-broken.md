# Fixture: broken links

This file is the failing fixture for the org link checker. It is deliberately
broken. `.github/workflows/tree-guards.yml` runs the check against this file
and requires a non-zero exit code. A link checker that cannot go red is worse
than no link checker, because its green gets read as evidence.

The repository-wide `link-check` job never sees this file: `.lychee.toml` at
the repository root excludes `tests/link-check/`.

Two failure classes, one each:

- A relative link to a file that does not exist: [missing document](./no-such-document.md)
- An anchor that no heading defines: [missing heading](fixture-ok.md#no-such-heading)

Nothing else in this file may break. The fixture asserts a non-zero exit, so a
third broken link would still pass the assertion while hiding a real defect.
