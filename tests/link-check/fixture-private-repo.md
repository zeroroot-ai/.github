<!-- link-check: fixture -->
# Fixture: references into repositories a public reader cannot open

This file is the failing fixture for `check-org-refs.sh`. The fixture job in
`.github/workflows/tree-guards.yml` runs the action against it as a public
caller and requires a non-zero exit code. The repository-wide job never sees
it: the marker on the first line keeps it out of the walk.

Three shapes, one each:

- A link into a private repository: [the estate](https://github.com/zeroroot-ai/hosted)
- A shorthand reference into a private repository: hosted#1
- A shorthand reference into a deleted repository: deploy#1
