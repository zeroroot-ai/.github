#!/usr/bin/env bash
#
# spdx-from-license.sh <dir> — print the SPDX id of the LICENSE file in <dir>,
# or in the repository root when <dir> has none.
#
# WHY THIS EXISTS. `docker/metadata-action` reads the licence from the GitHub
# API, and the API answers `NOASSERTION` for anything that is not an OSI
# licence it recognises. Elastic License 2.0 is not one, so every ELv2 image we
# publish carried:
#
#     org.opencontainers.image.licenses=NOASSERTION
#
# Measured on `ghcr.io/zeroroot-ai/gibson:latest`, 2026-09-16. A scanner and a
# procurement filter both read NOASSERTION as "unlicensed", which is a worse
# answer than the truth and is not one anybody chose.
#
# Classify from the licence TEXT instead, the same way the launch scorecard's
# readiness gate does. One rule, two places, same answer.
set -euo pipefail

dir="${1:-.}"
f="$dir/LICENSE"
[ -f "$f" ] || f="LICENSE"
if [ ! -f "$f" ]; then
  echo "LicenseRef-Unknown"
  exit 0
fi

# Pick the marker that appears FIRST, not the first arm of a case list.
#
# A licence names itself in its opening lines, but several of ours then list
# the licences of sibling repositories — `hosted` and `www` both open with an
# all-rights-reserved notice and later name Apache-2.0 and Elastic-2.0 repos.
# With a fixed arm order those files classify as whatever the case list happens
# to test first, and the answer depends on how many bytes of prefix are read.
# That is a coin toss, so order by position in the text instead.
head="$(head -c 800 "$f")"

best_id="LicenseRef-Unknown"
best_at=999999
consider() { # <marker> <spdx-id>
  local rest="${head#*"$1"}" at
  [ "$rest" = "$head" ] && return 0          # marker absent
  at=$(( ${#head} - ${#rest} - ${#1} ))      # byte offset of the match
  if [ "$at" -lt "$best_at" ]; then best_at=$at; best_id="$2"; fi
}

consider "Elastic License 2.0"     "Elastic-2.0"
consider "Apache License"          "Apache-2.0"
consider "MIT License"             "MIT"
consider "Business Source License" "BUSL-1.1"
consider "All rights reserved"     "LicenseRef-Proprietary"
consider "All Rights Reserved"     "LicenseRef-Proprietary"

echo "$best_id"
