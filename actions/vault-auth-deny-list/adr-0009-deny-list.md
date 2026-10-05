# ADR-0009 deny-list

This file is the source of the list. ADR-0009, "JWT + SPIFFE everywhere",
states the rule: no service uses the Kubernetes auth method of OpenBao or any
other TokenReview login. The ADR names this file as the list CI reads, and it
holds no copy of the list. Change the list here.

The reusable workflow at
`.github/workflows/vault-auth-method-deny-list.yml` reads this file
directly. The scanner script at `actions/vault-auth-deny-list/vault-auth-deny-list-scan.sh`
parses the table below (one literal-string row per token) and rejects
PRs that introduce any of these strings on a non-allowlisted line.

The parser only emits tokens from rows whose first column is exclusively
one or more backtick-wrapped strings separated by " / ". A row that mixes
prose and backticks describes a pattern that a literal scan cannot check, and
the parser skips it. The script header says why.

**Two rules that are not in the table, and why.** ADR-0009 also forbids a
Zitadel issuer as the bound issuer of the OpenBao JWT auth method. The two
places are the Helm value `vault.jwtAuth.boundIssuer` and a write to
`auth/jwt/config` with `bound_issuer`. Both keys are legitimate: the SPIRE
OIDC issuer is the correct value. The rule forbids one value of the key, not
the key, so a literal token for the key would fail every correct chart. No
scan here checks the value. Review is the only control for these two.

### Deny-list`
section in ADR-0009, "JWT + SPIFFE everywhere". The ADR lives in the
internal docs tree at `docs/adr/0009-jwt-spiffe-everywhere.md`.

The reusable workflow at
`.github/workflows/vault-auth-method-deny-list.yml` reads this file
directly. The scanner script at `actions/vault-auth-deny-list/vault-auth-deny-list-scan.sh`
parses the table below (one literal-string row per token) and rejects
PRs that introduce any of these strings on a non-allowlisted line.

**Why a vendored copy?**

The internal docs tree is not a GitHub repository. It was deleted on
2026-09-05 and now lives only in the local workspace, so no CI runner can
read the ADR. This snapshot is the only copy the scan has, at the cost of
one sync step when ADR-0009 grows.

**Sync contract.** When the deny-list table in ADR-0009 changes:

1. Update the ADR in the local workspace.
2. Open a PR on `zeroroot-ai/.github` that updates this file to match, in
   the same working session. This file must never lag the ADR.

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
