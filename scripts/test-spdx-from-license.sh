#!/usr/bin/env bash
#
# test-spdx-from-license.sh — the label must name the licence, never NOASSERTION.
#
# The fixture this exists for: `ghcr.io/zeroroot-ai/gibson:latest` shipped
# `org.opencontainers.image.licenses=NOASSERTION` because the GitHub API does
# not recognise Elastic License 2.0. A scanner reads that as "unlicensed".
#
# No network.
set -euo pipefail
cd "$(dirname "$0")/.."

S=actions/spdx-from-license/spdx-from-license.sh
PASS=0 FAIL=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

want() { # <dir> <expected> <what>
  local got; got=$("$S" "$1")
  if [ "$got" = "$2" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $3 -> '$got', expected '$2'"; fi
}

mk() { mkdir -p "$tmp/$1"; cat > "$tmp/$1/LICENSE"; }

mk elastic <<'L'
Copyright 2026 Zero Root AI

Elastic License 2.0

URL: https://www.elastic.co/licensing/elastic-license
L
want "$tmp/elastic" Elastic-2.0 "Elastic License 2.0"

mk apache <<'L'
                                 Apache License
                           Version 2.0, January 2004
L
want "$tmp/apache" Apache-2.0 "Apache-2.0"

mk mit <<'L'
MIT License

Copyright (c) 2023 ZITADEL
L
want "$tmp/mit" MIT "MIT"

mk busl <<'L'
Business Source License 1.1

Parameters
L
want "$tmp/busl" BUSL-1.1 "BUSL-1.1"

mk proprietary <<'L'
Copyright (c) 2026 Zero Root AI All rights reserved.

It is NOT distributed.
L
want "$tmp/proprietary" LicenseRef-Proprietary "all rights reserved"

# A directory with no LICENSE falls back to the repository root, which is this
# repo's Apache-2.0 file. That fallback is deliberate: a component subdirectory
# inherits its repository's licence.
mkdir -p "$tmp/bare"
want "$tmp/bare" Apache-2.0 "no LICENSE in the component dir, falls back to the repo root"

# THE REGRESSION. A licence file that lists OTHER repositories' licences after
# its own text must still classify as its own. `hosted` and `www` both do this:
# an all-rights-reserved notice followed by a table naming Apache-2.0 siblings.
mk mixed <<'L'
Copyright (c) 2026 Zero Root AI All rights reserved.

This repository is NOT distributed.

The product it deploys is licensed separately:

  zeroroot-ai/charts    Apache License 2.0
  zeroroot-ai/gibson    Elastic License 2.0
L
want "$tmp/mixed" LicenseRef-Proprietary "own licence wins over a sibling list"

# The label must never be the string the API produces for an unrecognised
# licence. That value is the whole reason this script exists.
for d in elastic apache mit busl proprietary mixed; do
  if [ "$("$S" "$tmp/$d")" = "NOASSERTION" ]; then
    FAIL=$((FAIL+1)); echo "  FAIL: $d classified as NOASSERTION"
  else PASS=$((PASS+1)); fi
done

# Every LICENSE shipped in THIS repo classifies to something real.
got=$("$S" .)
if [ "$got" = "Apache-2.0" ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: this repo classified as '$got', expected Apache-2.0"; fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
