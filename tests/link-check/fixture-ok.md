# Fixture ok

This file is the passing fixture for the org link checker.
`.github/workflows/tree-guards.yml` runs the check against this file and
requires exit code 0, so a checker that fails everything cannot be mistaken for
a working one.

One link of each class the broken fixture gets wrong:

- A relative link to a file that exists: [the broken fixture](fixture-broken.md)
- An anchor that a heading defines: [this heading](#fixture-ok)
