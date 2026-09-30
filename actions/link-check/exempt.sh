#!/usr/bin/env bash
# exempt.sh - the one list of Markdown the org policy never checks.
#
# Sourced by check-org-refs.sh, check-spelling.sh and changed-markdown.sh, so
# a directory sweep and a changed-files list exempt the same files. lychee
# keeps its own copy of the directory part in lychee.toml (`exclude_path`),
# because lychee reads its policy from that file and nothing else; the two
# must name the same directories.
#
# A file passed to a check by name (the `paths` input of the action) is not
# filtered here: the fixture job names its fixture files on purpose, and a
# caller that names a file wants it read.

# The marker a fixture file carries so a sweep of the tree skips it while the
# fixture job, which names the file, still reads it.
FIXTURE_MARKER="<!-- link-check: fixture -->"

# markdown_exempt <root> <file>: 0 when the org policy exempts the file from
# every check. <file> is relative to <root>.
#
#   generated trees   node_modules, vendor, dist, .next, .worktrees, .git
#   CHANGELOG.md      release-please owns it and rewrites it on every release;
#                     its links name pull requests, and the pre-reset ones no
#                     longer resolve
#   docs/adr/         the decision record keeps its pre-reset references by
#                     decision (.github#76)
#   fixture files     carry FIXTURE_MARKER
markdown_exempt() {
  local root="$1" file="$2"
  case "/${file}" in
    */node_modules/*|*/.git/*|*/vendor/*|*/dist/*|*/.next/*|*/.worktrees/*) return 0 ;;
    */CHANGELOG.md|*/docs/adr/*) return 0 ;;
  esac
  if [ -f "${root}/${file}" ] && grep -qF "$FIXTURE_MARKER" "${root}/${file}"; then
    return 0
  fi
  return 1
}
