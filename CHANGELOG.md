# Changelog

## [0.5.2](https://github.com/zeroroot-ai/.github/compare/v0.5.1...v0.5.2) (2026-09-18)


### Bug Fixes

* **coverage-gate:** fetch the comparator script at the pinned workflow SHA ([#105](https://github.com/zeroroot-ai/.github/issues/105)) ([5e4aff4](https://github.com/zeroroot-ai/.github/commit/5e4aff4559731b4933a62d3b68e08c5cd7579ffa))
* **rulesets:** protect the .github repository with its own ruleset ([#106](https://github.com/zeroroot-ai/.github/issues/106)) ([bad7108](https://github.com/zeroroot-ai/.github/commit/bad7108dca8dcf76d714951e77b0c652a728980e))
* **scorecard:** blocker 2 has a root issue again ([#103](https://github.com/zeroroot-ai/.github/issues/103)) ([0a27cb3](https://github.com/zeroroot-ai/.github/commit/0a27cb3ce7e71d4f3c7b4a6346751758f7e3b815))
* **version-fanout:** run regenerate commands without the fan-out tokens ([#108](https://github.com/zeroroot-ai/.github/issues/108)) ([e4e1c02](https://github.com/zeroroot-ai/.github/commit/e4e1c028953040246b14236b31924fb0c9a8f2ef))

## [0.5.1](https://github.com/zeroroot-ai/.github/compare/v0.5.0...v0.5.1) (2026-09-17)


### Bug Fixes

* **reusables:** pin the org actions at v0.5.0 ([#100](https://github.com/zeroroot-ai/.github/issues/100)) ([512a133](https://github.com/zeroroot-ai/.github/commit/512a1334430e32b7abe76299418eea17749fca1d))

## [0.5.0](https://github.com/zeroroot-ai/.github/compare/v0.4.1...v0.5.0) (2026-09-17)


### Features

* **link-check:** fail what a public reader cannot follow ([#98](https://github.com/zeroroot-ai/.github/issues/98)) ([570f805](https://github.com/zeroroot-ai/.github/commit/570f805058a0870a5f9d20025c2fe6bb96f2e568))

## [0.4.1](https://github.com/zeroroot-ai/.github/compare/v0.4.0...v0.4.1) (2026-09-17)


### Bug Fixes

* **guard:** stop exempting .github from its own unpinned-actions check ([#93](https://github.com/zeroroot-ai/.github/issues/93)) ([4d00166](https://github.com/zeroroot-ai/.github/commit/4d00166dc6022754e1edcd47389b8d623a076140))
* **scorecard:** blocker 5 exit test lives in hosted ([#94](https://github.com/zeroroot-ai/.github/issues/94)) ([2f3fec1](https://github.com/zeroroot-ai/.github/commit/2f3fec1b6449b272c2d7718a671b83c1d65565c2))
* **verify-release:** verify the identity the shared build signs with ([#96](https://github.com/zeroroot-ai/.github/issues/96)) ([03f9b3c](https://github.com/zeroroot-ai/.github/commit/03f9b3c86dd2f7d29965c15f7319534fdbd569fb))

## [0.4.0](https://github.com/zeroroot-ai/.github/compare/v0.3.0...v0.4.0) (2026-09-16)


### Features

* **guard:** the drift guard asserts the three org Actions settings ([#90](https://github.com/zeroroot-ai/.github/issues/90)) ([7c6b946](https://github.com/zeroroot-ai/.github/commit/7c6b946c85ad9725eb658ba438f834feba1bc878))


### Bug Fixes

* **ci:** pin upload-artifact by SHA inside the flake-quarantine action ([#92](https://github.com/zeroroot-ai/.github/issues/92)) ([49b8c12](https://github.com/zeroroot-ai/.github/commit/49b8c12a1d3652f4c79361341c8188c147472acd))

## [0.3.0](https://github.com/zeroroot-ai/.github/compare/v0.2.0...v0.3.0) (2026-09-16)


### Features

* **ci:** pin this repo's own actions to v0.2.0, not [@main](https://github.com/main) ([#88](https://github.com/zeroroot-ai/.github/issues/88)) ([3d1a2b1](https://github.com/zeroroot-ai/.github/commit/3d1a2b1266f47a68e410988bed7a63efa9dce12b))

## [0.2.0](https://github.com/zeroroot-ai/.github/compare/v0.1.0...v0.2.0) (2026-09-16)


### Features

* **drift:** declare the charts subchart image overrides ([#32](https://github.com/zeroroot-ai/.github/issues/32)) ([65ae67f](https://github.com/zeroroot-ai/.github/commit/65ae67fd70b8d3285616f4b156021e58a2ea01d9))
* **drift:** declare the setec kata link ([#33](https://github.com/zeroroot-ai/.github/issues/33)) ([53c67ea](https://github.com/zeroroot-ai/.github/commit/53c67ea22d20b33db5c43f17ea6456068ce2632f))
* **drift:** the alpine-k8s link sources the charts global.toolImage ([#41](https://github.com/zeroroot-ai/.github/issues/41)) ([598650f](https://github.com/zeroroot-ai/.github/commit/598650f15891b77188c68289fd67158c1f099776))
* **drift:** version-links.yaml and a scheduled version-drift detector, ZITADEL first ([#27](https://github.com/zeroroot-ai/.github/issues/27)) ([e099283](https://github.com/zeroroot-ai/.github/commit/e0992834fb0c832dc927515e1c46f985015ed7ed)), closes [#21](https://github.com/zeroroot-ai/.github/issues/21) [#20](https://github.com/zeroroot-ai/.github/issues/20)
* **fanout:** reusable version fan-out that opens one consumer PR per link ([#31](https://github.com/zeroroot-ai/.github/issues/31)) ([f760edb](https://github.com/zeroroot-ai/.github/commit/f760edb01410e83c4e262218b80f64d939fe80f3)), closes [#24](https://github.com/zeroroot-ai/.github/issues/24) [#20](https://github.com/zeroroot-ai/.github/issues/20)
* **go-ci:** guard that the builder image matches the go.mod toolchain, GOTOOLCHAIN=local in image builds ([#29](https://github.com/zeroroot-ai/.github/issues/29)) ([1499bdf](https://github.com/zeroroot-ai/.github/commit/1499bdfefd130fe7d1366b2474b12c7b8a9635fb)), closes [#22](https://github.com/zeroroot-ai/.github/issues/22) [#20](https://github.com/zeroroot-ai/.github/issues/20)
* **guards:** one org brand guard and one org link checker ([#54](https://github.com/zeroroot-ai/.github/issues/54)) ([43c3234](https://github.com/zeroroot-ai/.github/commit/43c323476e14eb420406370788e470f0af9e8800))
* **images:** fail a build whose image ships no licence text ([#82](https://github.com/zeroroot-ai/.github/issues/82)) ([d33b5cc](https://github.com/zeroroot-ai/.github/commit/d33b5cc18ac03d012f37f6e54984ed5f994da41b))
* **images:** pass APT_CACHE_BUST to every build, always ([#84](https://github.com/zeroroot-ai/.github/issues/84)) ([1df6a37](https://github.com/zeroroot-ai/.github/commit/1df6a37570dce06fc16163c24d605cb090241717))
* **images:** scan before push, and block a fixable HIGH or CRITICAL ([#85](https://github.com/zeroroot-ai/.github/issues/85)) ([0fed786](https://github.com/zeroroot-ai/.github/commit/0fed78673650eb244156e92f3a37ab7411e39750))
* **node-ci:** one Node version file per repo, setup-node reads it, Dockerfile FROM guarded against it ([#30](https://github.com/zeroroot-ai/.github/issues/30)) ([bcb3d77](https://github.com/zeroroot-ai/.github/commit/bcb3d77b816e2dc782c2c64e8fd0c82fc1bbffb1)), closes [#23](https://github.com/zeroroot-ai/.github/issues/23) [#20](https://github.com/zeroroot-ai/.github/issues/20)
* **release:** publish releases, so consumer pins can be bumped by a machine ([#86](https://github.com/zeroroot-ai/.github/issues/86)) ([153123c](https://github.com/zeroroot-ai/.github/commit/153123c5007e933c60dd126d926356ff3746ec1f))
* **rulesets:** require brand-guard and link-check on every public repo ([#55](https://github.com/zeroroot-ai/.github/issues/55)) ([1028c97](https://github.com/zeroroot-ai/.github/commit/1028c973c45ed147dc16384acb19c44efd7f1af8))
* **scorecard:** BUSL blocks publication, and www is never published ([#79](https://github.com/zeroroot-ai/.github/issues/79)) ([c650b59](https://github.com/zeroroot-ai/.github/commit/c650b5999074e1c137b1272a842f61725ea513bc))
* **scorecard:** hide passing rows, measure open-source readiness ([#71](https://github.com/zeroroot-ai/.github/issues/71)) ([3cefe73](https://github.com/zeroroot-ai/.github/commit/3cefe7327326a75d8ba966ea106ac4d1e99d2453))
* **scorecard:** repos that are never published leave the readiness gate ([#77](https://github.com/zeroroot-ai/.github/issues/77)) ([8b17bd6](https://github.com/zeroroot-ai/.github/commit/8b17bd6d23bfb824c6630839f9c905af0e4b7dc5))


### Bug Fixes

* **ci:** drop the ghtoken buildx secret from reusable-image-build ([#50](https://github.com/zeroroot-ai/.github/issues/50)) ([08aa83a](https://github.com/zeroroot-ai/.github/commit/08aa83ad3d2aecf914df602bdf038c5c63de11c9))
* **ci:** drop the GitHub Packages token plumbing from the reusable workflows ([#48](https://github.com/zeroroot-ai/.github/issues/48)) ([db371aa](https://github.com/zeroroot-ai/.github/commit/db371aa6f23ab80e00b1359327c0ba21cb320f8d))
* **ci:** make the gitleaks self-test token always 24 characters ([#49](https://github.com/zeroroot-ai/.github/issues/49)) ([16d878c](https://github.com/zeroroot-ai/.github/commit/16d878c3c34154e58c31164fbe32bf597575f9c1))
* **ci:** retry the curl downloads in the reusable lint/coverage workflows ([#57](https://github.com/zeroroot-ai/.github/issues/57)) ([f1fd10b](https://github.com/zeroroot-ai/.github/commit/f1fd10b87100712643b3888453beff7ebf5a4af2))
* **ci:** scan images with ignore-unfixed so only actionable CVEs reach code scanning ([#19](https://github.com/zeroroot-ai/.github/issues/19)) ([ff1284a](https://github.com/zeroroot-ai/.github/commit/ff1284a9ffcb2cd1d2437de2b5bd214de24878b3))
* **ci:** the ADR-0088 drift guard uses REST, not GraphQL ([#6](https://github.com/zeroroot-ai/.github/issues/6)) ([c348d3d](https://github.com/zeroroot-ai/.github/commit/c348d3d636ac663bacda8197ba484f08b4a47956))
* **ci:** the private-repo canary is hosted, gitops no longer exists ([#8](https://github.com/zeroroot-ai/.github/issues/8)) ([e775c50](https://github.com/zeroroot-ai/.github/commit/e775c50231656fece8a53883dbf8aa6ddc298416))
* **drift:** a tool image records the subchart appVersion without comparing against it ([#34](https://github.com/zeroroot-ai/.github/issues/34)) ([32ea38b](https://github.com/zeroroot-ai/.github/commit/32ea38bdf44e60935f734bab93df880da72fff93))
* **fanout:** give the rerun push a lease that names the remote tip ([#38](https://github.com/zeroroot-ai/.github/issues/38)) ([09e5146](https://github.com/zeroroot-ai/.github/commit/09e514613056fa6858289a6f6d07cd9bb01213dd))
* **fanout:** run the consumer's declared regeneration before the commit ([#37](https://github.com/zeroroot-ai/.github/issues/37)) ([4312519](https://github.com/zeroroot-ai/.github/commit/4312519c45902bcd581a1afdc7aad26c19cd0d63))
* **guard:** first-party reusable refs must be SHA-pinned, and the template was not ([#66](https://github.com/zeroroot-ai/.github/issues/66)) ([d09e1de](https://github.com/zeroroot-ai/.github/commit/d09e1dee23122cea56786cf508fe78c1e7d04780))
* **images:** label the licence instead of NOASSERTION ([#80](https://github.com/zeroroot-ai/.github/issues/80)) ([625c0b9](https://github.com/zeroroot-ai/.github/commit/625c0b92ef329bfe40f11f639ee6136c8706538b))
* **rework:** escape the backticks the scorecard heredoc ate ([#72](https://github.com/zeroroot-ai/.github/issues/72)) ([66dbe28](https://github.com/zeroroot-ai/.github/commit/66dbe28196cff420cc5253675042e4db8eb94c07))
* **rework:** strip helper output in the push-lease self-test ([#39](https://github.com/zeroroot-ai/.github/issues/39)) ([03e20c0](https://github.com/zeroroot-ai/.github/commit/03e20c0508d3dae2d7f34ab03c4fe60123456957))
* **rework:** the licence guard was spliced into the build step's inputs ([#83](https://github.com/zeroroot-ai/.github/issues/83)) ([cc9c979](https://github.com/zeroroot-ai/.github/commit/cc9c979345bd1940cb070a455e0b7a49004c9bac))
* **rework:** the readiness heading claimed every repo becomes public ([#78](https://github.com/zeroroot-ai/.github/issues/78)) ([5113003](https://github.com/zeroroot-ai/.github/commit/511300321f1923f4f98fe13a6de8d3db99b5b6ab))
* **sarif-triage:** a repo without Code Security is nothing to triage ([#9](https://github.com/zeroroot-ai/.github/issues/9)) ([68610f6](https://github.com/zeroroot-ai/.github/commit/68610f66f9e3553491d83c7bd7b8b05a6758deda))
* **scorecard:** a deleted workflow is NOT_BUILT, not its last green run ([#70](https://github.com/zeroroot-ai/.github/issues/70)) ([4152176](https://github.com/zeroroot-ai/.github/commit/41521768f960bc257bd6b68db4104ebc8580cf65))
* **scorecard:** S1 vanilla install runs in hosted, not charts ([#47](https://github.com/zeroroot-ai/.github/issues/47)) ([9d8932b](https://github.com/zeroroot-ai/.github/commit/9d8932b15b99d53c8b68be3ae8b973d4777417e4))
* **triage:** close a repo's digest when it reaches zero open alerts ([#67](https://github.com/zeroroot-ai/.github/issues/67)) ([b7a142c](https://github.com/zeroroot-ai/.github/commit/b7a142c4432492ada621d7603a676d0a3f7f8044))
