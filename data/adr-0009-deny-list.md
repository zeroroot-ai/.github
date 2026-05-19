# ADR-0009 deny-list (vendored snapshot)

This file is a vendored, parse-stable snapshot of the `### Deny-list`
section in
[zero-day-ai/docs/adr/0009-jwt-spiffe-everywhere.md](https://github.com/zero-day-ai/docs/blob/main/adr/0009-jwt-spiffe-everywhere.md).

The reusable workflow at
`.github/workflows/vault-auth-method-deny-list.yml` reads this file
directly. The scanner script at `scripts/vault-auth-deny-list-scan.sh`
parses the table below (one literal-string row per token) and rejects
PRs that introduce any of these strings on a non-allowlisted line.

**Why a vendored copy?**

`zero-day-ai/docs` is a private repository. Some consumer repos (notably
`setec`, an OSS repo) don't have access to the `DOCS_REPO_READ_TOKEN`
org-level secret, so cross-repo `actions/checkout` of the docs repo
fails. Vendoring the deny-list eliminates the docs-repo dependency
entirely, at the cost of an extra sync step when ADR-0009 grows.

**Sync contract.** When the deny-list table in ADR-0009 changes:

1. Open a PR on `zero-day-ai/docs` that updates the ADR.
2. After the ADR PR merges, open a follow-up PR on `zero-day-ai/.github`
   that updates this file to match. The two are reviewed together; the
   intent is that this file never lags the ADR by more than one PR cycle.
3. A future workflow on `zero-day-ai/docs` may auto-open the
   `.github`-repo sync PR — tracked separately.

The parser only emits tokens from rows whose first column is exclusively
one or more backtick-wrapped strings separated by " / " (the
ADR's convention for grouping aliases). Rows that mix prose and
backticks describe structural patterns that need human review, not
literal-string rejection, and are silently skipped — see the script
header for why.

### Deny-list

| Forbidden token | Where it would appear if reintroduced |
| --- | --- |
| `AuthMethodKubernetes` | Go SDK constant — must not exist |
| `case AuthMethodKubernetes` | Go switch dispatch — must not exist |
| `auth/kubernetes` | URL path in any HTTP request, CRD field, or chart value |
| `vault/api/auth/kubernetes` | Go import — must not exist |
| `hashicorp/vault/api/auth/kubernetes` | Go import — must not exist |
| `kubernetes-auth-init` | Job / template / Service name |
| `vault.kubernetesAuth` | Helm values path |
| `GIBSON_VAULT_AUTH_METHOD=kubernetes` | Operator deployment env or any other env block |
| `mountPath: "/v1/auth/kubernetes"` | cert-manager Vault Issuer config |
| `mountPath: /v1/auth/kubernetes` | cert-manager Vault Issuer config (unquoted form) |
| `exchangeZitadelForVault` / `ZitadelToVault` / similar named function | Implies a code path that trades a Zitadel JWT for a Vault token at runtime |
