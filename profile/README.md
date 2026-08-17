<div align="center">

```
╔══════════════════════════════════════════════════════════════╗
║                                                              ║
║   ███████╗███████╗██████╗  ██████╗ ██████╗  ██████╗  ██████╗████████╗  ║
║   ╚══███╔╝██╔════╝██╔══██╗██╔═══██╗██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝  ║
║     ███╔╝ █████╗  ██████╔╝██║   ██║██████╔╝██║   ██║██║   ██║   ██║     ║
║    ███╔╝  ██╔══╝  ██╔══██╗██║   ██║██╔══██╗██║   ██║██║   ██║   ██║     ║
║   ███████╗███████╗██║  ██║╚██████╔╝██║  ██║╚██████╔╝╚██████╔╝   ██║     ║
║   ╚══════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝   ╚═╝     ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
```

# Gibson — an agent factory for platform and security engineering

**A do-it-yourself ADK and runtime. You write the agent; Gibson gives it an identity, a grant for every tool it can touch, a sandbox, and a replayable record of what it did.**

[![Discord](https://img.shields.io/badge/Discord-Join_Community-7289DA?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/mkqd6mU3)
[![Docs](https://img.shields.io/badge/Docs-docs.zeroroot.ai-blue?style=for-the-badge)](https://docs.zeroroot.ai)

</div>

---

Writing an agent is an afternoon's work. Running a fleet of them somewhere your
security review will accept is the hard part, and it is the same hard part
whether the agent patches CVEs, reconciles config, or triages alerts:

- Which human is answerable for this agent?
- What is it allowed to touch, and who can revoke that?
- What happens when one is prompt-injected, or simply wrong?
- Can you show, afterwards, exactly what it did?

Gibson answers those once, in the runtime, so every agent you build inherits the
answers.

**The deep technical document is [docs.zeroroot.ai/docs/security](https://docs.zeroroot.ai/docs/security)** — one page per control domain, each claim naming the file, flag, or ADR that proves it. This page is the overview.

---

## What people build

- **CVE response.** An agent that reacts to a newly published advisory, works out
  which services in the graph are affected, and opens the patch PR.
- **Coding agents under control.** Run `opencode` and friends inside a sandbox,
  under grants, with everything they did on the record.
- **Ops automation.** Reconcile drift, chase SLO burn, sweep IOCs across audit
  logs.
- **Offensive and defensive security.** Recon, triage, and evidence collection —
  one domain among several, not the boundary.

---

## Build a component

```bash
go install github.com/zeroroot-ai/adk/cmd/gibson@latest

gibson init --gibson-url https://api.zeroroot.ai
gibson component init slo-checker --kind tool
cd slo-checker && claude
```

The scaffold contains the contract your AI coder needs — `AGENTS.md`, proto
layout, graph wiring, and step-by-step recipes — so you describe what you want
and it writes a correct implementation. Its shell allowlist is deliberately
narrow: the coding agent can build, validate, and register, but cannot
`kubectl apply`, `helm install`, or write outside the component directory.

```bash
gibson component register --client-id <id> --client-secret -
gibson component run
```

### Three component shapes

| Kind | What it is | Built with |
|------|------------|------------|
| **agent** | Model-driven gRPC service — reasons, plans, delegates to tools | `sdk.NewAgent` + `serve.Agent` |
| **tool** | Stateless proto-in / proto-out executor | `serve.Tool` |
| **plugin** | Stateful integration with declared methods and lifecycle | `plugin.Serve` |

Every tool response reserves field 100 for a `DiscoveryResult`. Fill it and what
the tool found lands in the knowledge graph automatically — no query language, no
ingestion pipeline.

You are not starting from nothing: `gibson-executor` is one microVM image with
parsers for common security and ops command-line tools, and `zerocool-plugins`
puts a coding agent under Gibson's controls. Compose those, or write your own.

---

## The controls

Each row links to the page that proves it.

| | What Gibson does |
|---|---|
| **[Identity](https://docs.zeroroot.ai/docs/security/identity)** | Two planes. In-cluster: SPIFFE mTLS plus JWTs, trust domain `zeroroot.ai`. Off-cluster: an Ed25519 host key at `0600`, then per-call tokens that expire in 55 seconds. The complete list of static credentials in the platform is two entries long, and it is published. |
| **[Authorization](https://docs.zeroroot.ai/docs/security/authorization)** | An OpenFGA model. Agents, tools and plugins are their own principal types, each with `owner: [user]`. Read, configure and execute are separate grants. A disable at tenant, team or user scope is subtracted from the grant, so it cannot be out-voted. |
| **[Isolation](https://docs.zeroroot.ai/docs/security/isolation)** | One fail-closed gate decides: deny, Firecracker microVM, or in-process. When a sandbox is available it is always used. Untrusted code has no in-process fallback on hosted infrastructure — if the sandbox is gone, the call is refused. |
| **[Tenancy](https://docs.zeroroot.ai/docs/security/tenancy)** | One graph database per tenant, in its own namespace. Nodes carry no tenant identifier, because there is nothing to disambiguate. There is no cross-tenant query to get wrong. |
| **[Runtime](https://docs.zeroroot.ai/docs/security/runtime)** | Missions run on a persistent event-sourced loop. Constraints on the mission cap duration, cost, tokens, turns, findings, tools and domains. **No human approves an action mid-run** — control is declared up front, and that is a documented decision. |
| **[Audit](https://docs.zeroroot.ai/docs/security/audit)** | Every model call is recorded with an immutable transcript and token counts, inside your tenant. No third-party trace vendor sits on that path. Every mission replays from its timeline. |
| **[Supply chain](https://docs.zeroroot.ai/docs/security/supply-chain)** | One versioned OCI umbrella chart that pins every first-party image by digest at package time. Rollback is pinning the previous version. Big Bang compatible: Flux-wrappable, hardened, no service-mesh assumption. |

Two things Gibson deliberately does **not** do, stated here so nobody discovers
them later:

- **It owns no clock.** No cron, no trigger on a mission. Missions start from your
  CI, your webhook, your alert manager, or your scheduler.
- **It does not ask a human to approve an action mid-run.** The grants and the
  mission constraints are the control, and they are set before it starts.

---

## Where your agents run

```
 EXECUTION PLANE                   │  CONTROL PLANE · api.zeroroot.ai
 ┌────────────────────┐            │  ┌───────────────────────────────┐
 │ ● your agent       │            │  │ ● orchestration + missions    │
 │   runs on:         │  ═══════►  │  │ ● shared knowledge graph      │
 │   laptop · ci ·    │  capability│  │ ● grants (OpenFGA)            │
 │   vps · k8s        │  grant     │  │ ● audit + replay              │
 └──────────┬─────────┘            │  │ ● sandbox (setec microVMs)    │
            │                      │  └───────────────────────────────┘
            ▼
 ● BYOK → anthropic · openai · bedrock · gemini · ollama
```

An agent declares the model **slot** it needs; the platform resolves it at
runtime. No provider SDK in your binary, no model lock-in, and your keys stay
where your team put them.

---

## The knowledge graph is shared memory

What one agent discovers, the next one starts from. The graph is defined by a
single taxonomy in the SDK; one generator compiles it into the proto, Go types,
graph schema, validators and query helpers together, so the whole stack moves in
step.

**The taxonomy is yours.** You do not fork it — you layer a `TaxonomyExtension`
with your own node types and relationships on top. Every type records where it
came from, so a platform upgrade cannot overwrite your model and your additions
are never mistaken for defaults. Model `Vendor`, `Incident`, `Control`, or
`Shipment` if that is what your organisation thinks in.

---

## Repos

| Repo | What it is | Licence |
|---|---|---|
| **[`gibson`](https://github.com/zeroroot-ai/gibson)** | The control plane — daemon, brain, operators, authorization model | Elastic-2.0 |
| **[`sdk`](https://github.com/zeroroot-ai/sdk)** | Go SDK — agent, tool and plugin contracts, harness API, graph wiring | Apache-2.0 |
| **[`adk`](https://github.com/zeroroot-ai/adk)** | The `gibson` CLI — scaffold, build, validate, enrol, submit missions | Apache-2.0 |
| **[`setec`](https://github.com/zeroroot-ai/setec)** | Kubernetes operator for Firecracker microVMs via Kata. Useful standalone | Apache-2.0 |
| **[`gibson-executor`](https://github.com/zeroroot-ai/gibson-executor)** | One microVM image, one binary, parsers for common security and ops tools | Apache-2.0 |
| **[`zerocool-plugins`](https://github.com/zeroroot-ai/zerocool-plugins)** | opencode plugins — a coding agent under Gibson's controls | MIT |
| **[`dashboard`](https://github.com/zeroroot-ai/dashboard)** | The web interface | Elastic-2.0 |

Also public: [`sdk-ts`](https://github.com/zeroroot-ai/sdk-ts) and
[`python-sdk`](https://github.com/zeroroot-ai/python-sdk).

**Licensing in two sentences.** Everything you build against is Apache-2.0 or
MIT — what you write is yours, with no obligation back to us. The control plane
and dashboard are Elastic License 2.0: read, run, modify and self-host them, but
do not offer them to third parties as a managed service and do not remove the
licence-key check. Neither restricts internal use. Details:
[licensing](https://docs.zeroroot.ai/docs/security/licensing).

---

## Consulting

We work as forward-deployed engineers: our engineers embed with your team to
build the agents, the components, and the missions on your own infrastructure.

**[consulting@zeroroot.ai](mailto:consulting@zeroroot.ai)**

---

## Stack

| Layer | Technology |
|---|---|
| Languages | Go 1.26, TypeScript 5.9, Python |
| Web | Next.js, React, Tailwind, Shadcn UI |
| RPC | gRPC + Protocol Buffers, Buf |
| Identity | SPIFFE/SPIRE in-cluster; Ed25519 capability grants off-cluster; Zitadel OIDC |
| Authorization | OpenFGA (Zanzibar model) |
| Mission definition | CUE |
| Sandbox | Firecracker + Kata, via setec |
| Knowledge graph | Neo4j |
| Secrets | OpenBao |
| Observability | OpenTelemetry, Prometheus |
| Deployment | Kubernetes, Helm, one versioned OCI umbrella chart |

---

<div align="center">

**[Read the security docs →](https://docs.zeroroot.ai/docs/security)** · **[Build with the SDK →](https://github.com/zeroroot-ai/sdk)** · **[Get the ADK →](https://github.com/zeroroot-ai/adk)** · **[Join Discord](https://discord.gg/mkqd6mU3)**

</div>
