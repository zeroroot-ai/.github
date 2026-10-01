# makefile-contract fixtures

Each subdirectory is one repo as `scripts/check-makefile-contract.sh --scan-dir`
sees it. `scripts/test-makefile-contract.sh` drives them.

| Fixture | Shape | Guard must |
|---|---|---|
| `complete` | all three targets | pass |
| `missing-test` | `build` and `check` only | name `test` |
| `missing-all` | no contracted target | name all three |
| `no-makefile` | empty repo | say "no Makefile" |
| `charts` | an exempt repo name, no Makefile | be skipped |

One fixture is **not** committed: the large-Makefile case the test generates at
run time (`large_complete`). It has to outgrow the reader's buffer to reproduce
.github#141, which puts it well past any size worth keeping in the tree.
