<!-- link-check: fixture -->
# Fixture: pre-reset issue numbers

This file is the failing fixture for the pre-reset check in
`check-org-refs.sh`. The history reset of 2026-09-05 renumbered every
repository from 1, so a number above the newest issue or pull request cannot
resolve. The fixture job requires a non-zero exit code on this file.

Two shapes, one each:

- A cross-repository number: gibson#99999
- A number in the calling repository: #99999
