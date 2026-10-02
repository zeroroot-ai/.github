# reachable-ids.jq — turn `govulncheck -mode=binary -json` output into the set of
# advisory ids whose affected symbol is ACTUALLY PRESENT in the binary.
#
# THE BUG THIS FILE EXISTS TO PREVENT. govulncheck streams two different kinds of
# message that both carry an advisory:
#
#   {"osv": {...}}      a DEFINITION. One is emitted for every advisory the tool
#                       loaded from the database, whether or not it applies.
#   {"finding": {...}}  a RESULT. Emitted only for a vulnerability govulncheck
#                       actually found in this binary.
#
# The first version of this collector read `.osv` and so returned every advisory
# in the database: 350 ids for each gVisor binary and 665 for kata's shim. Every
# finding then looked reachable, nothing could ever be judged unreachable, and the
# gate blocked all 11 gVisor findings for a reason that had nothing to do with
# gVisor. It failed safe and it was useless.
#
# So: read `.finding`. The definitions are read only to resolve aliases, because
# an image scanner names CVE-YYYY-NNNNN and govulncheck names GO-YYYY-NNNN.
#
# In -mode=binary a finding's trace carries a function when govulncheck matched a
# symbol, and no function when it could only match the module. Both are reported
# here: a module-level match means the tool could not rule the vulnerability out,
# and this gate must not treat "could not tell" as "not present".
[inputs]
| (map(select(has("osv")) | .osv) | map({key: .id, value: ((.aliases // []))}) | from_entries) as $aliases
| [ .[]
    | select(has("finding"))
    | .finding.osv
    | select(. != null)
  ]
| unique
| map([.] + ($aliases[.] // []))
| flatten
| unique
| .[]
