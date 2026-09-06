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

# Gibson: the runtime that gets an AI agent past a security review

**You write the agent. Gibson gives it an identity and a grant for every tool it can touch. It gives it a microVM for untrusted work and a replayable record of what it did.**

[![Discord](https://img.shields.io/badge/Discord-Join_Community-7289DA?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/mkqd6mU3)
[![Docs](https://img.shields.io/badge/Docs-docs.zeroroot.ai-blue?style=for-the-badge)](https://docs.zeroroot.ai)

</div>

---

An agent takes an afternoon to write. A fleet of agents that a security review
accepts is the hard part. The hard part is the same whether the agent patches
CVEs, reconciles config, or triages alerts:

- Which human is answerable for this agent?
- What can it touch, and who can revoke that?
- What happens when someone prompt-injects it, or when it is simply wrong?
- Can you show, afterwards, exactly what it did?

Gibson answers those questions once, in the runtime. Every agent you build
inherits the answers.

**The deep technical document is [docs.zeroroot.ai/docs/security](https://docs.zeroroot.ai/docs/security).**
It has one page per control domain, and each claim names the file, flag, or ADR
that proves it. This page is the overview.

---

## What people build

- **CVE response.** An agent reacts to a new advisory, works out which services
  in the graph are affected, and opens the patch PR.
- **Coding agents under control.** Run `opencode` inside a microVM, under
  grants, with everything it did on the record.
- **Ops automation.** Reconcile drift, chase SLO burn, sweep IOCs across audit
  logs.
- **Offensive and defensive security.** Recon, triage, and evidence collection.
  This is one domain among several, not the boundary.

---

## Build a component

```bash
go install github.com/zeroroot-ai/adk/gibson/cmd/gibson@latest

gibson init --gibson-url https://api.zeroroot.ai
gibson component init slo-checker --kind tool
cd slo-checker && claude
```

The scaffold contains the contract your AI coding agent needs: `AGENTS.md`, the
proto layout, the graph wiring, and step-by-step recipes. You describe what you
want, and the coding agent writes a correct implementation. Its shell allowlist
is narrow on purpose. The coding agent can build, validate, and register. It
cannot run `kubectl apply` or `helm install`, and it cannot write outside the
component directory.

```bash
gibson component register --token <bootstrap-token>
gibson component run
```

### Three component shapes

| Kind | What it is | Built with |
|------|------------|------------|
| **agent** | A model-driven gRPC service. It reasons, plans, and delegates to tools | `sdk.NewAgent` + `serve.Agent` |
| **tool** | A stateless proto-in, proto-out executor | `serve.Tool` |
| **plugin** | A stateful integration with declared methods and a lifecycle | `plugin.Serve` |

Every tool response reserves field 100 for a `DiscoveryResult`. Fill it, and
what the tool found lands in the knowledge graph. There is no query language to
learn and no ingestion pipeline to build.

You do not start from nothing. `gibson-executor` is one microVM image with
parsers for common security and ops command-line tools. `zerocool` puts a
coding agent under Gibson's controls. Compose those, or write your own.

---

## The controls

Each row links to the page that proves it.

| | What Gibson does |
|---|---|
| **[Identity](https://docs.zeroroot.ai/docs/security/identity)** | Two planes. In the cluster: SPIFFE mTLS plus JWTs, trust domain `zeroroot.ai`. Off the cluster: an Ed25519 host key at `0600`, then per-call tokens that expire in 55 seconds. The platform holds two static credentials in total, and it publishes that list. |
| **[Authorization](https://docs.zeroroot.ai/docs/security/authorization)** | An OpenFGA model. Agents, tools and plugins are their own principal types, each with `owner: [user]`. Read, configure and execute are separate grants. A disable at tenant, team or user scope subtracts from the grant, so no vote can override it. |
| **[Isolation](https://docs.zeroroot.ai/docs/security/isolation)** | One fail-closed gate decides: deny, Firecracker microVM, or in process. When a microVM is available, the gate always uses it. Untrusted code has no in-process fallback on hosted infrastructure. If the microVM is gone, the gate refuses the call. |
| **[Tenancy](https://docs.zeroroot.ai/docs/security/tenancy)** | One graph database per tenant, in its own namespace. Nodes carry no tenant identifier, because there is nothing to disambiguate. There is no cross-tenant query to get wrong. |
| **[Runtime](https://docs.zeroroot.ai/docs/security/runtime)** | Missions run on a persistent event-sourced loop. Constraints on the mission cap duration, cost, tokens, turns, findings, tools and domains. A person declares control before the run starts. |
| **[Audit](https://docs.zeroroot.ai/docs/security/audit)** | The platform records every model call with an immutable transcript and token counts, inside your tenant. No third-party trace vendor sits on that path. Every mission replays from its timeline. |
| **[Supply chain](https://docs.zeroroot.ai/docs/security/supply-chain)** | One versioned OCI umbrella chart pins every first-party image by digest at package time. To roll back, pin the previous version. Big Bang compatible: Flux-wrappable, hardened, no service-mesh assumption. |

---

## Where it runs

Gibson Runtime, Gibson Console and the execution environment (Setec microVMs)
run together in one Kubernetes cluster. zeroroot hosts that cluster for you, or
you install it in your own Kubernetes. Your own Kubernetes can be in any cloud
or on your own metal, up to fully air-gapped.

Your agents do not have to be in that cluster. They run wherever the work is: a
laptop, a CI runner, a box on your network, or your own cluster. They check in
to the runtime over the network. When you host the runtime, in-cluster agents
can also use mTLS.

An agent declares the model **slot** it needs, and the runtime resolves the slot
at run time. There is no provider SDK in your binary and no model lock-in. Your
keys stay where your team put them.

---

## The knowledge graph is shared memory

What one agent discovers, the next one starts from. A single taxonomy in the
SDK defines the graph. One generator compiles that taxonomy into the proto, the
Go types, the graph schema, the validators and the query helpers. The whole
stack moves in step.

**The taxonomy is yours.** You do not fork it. You layer a `TaxonomyExtension`
with your own node types and relationships on top. Every type records where it
came from, so a platform upgrade cannot overwrite your model, and nobody can
mistake your additions for defaults. Model `Vendor`, `Incident`, `Control`, or
`Shipment` if that is what your organization thinks in.

---

## Repositories

| Repo | What it is | License |
|---|---|---|
| **[`adk`](https://github.com/zeroroot-ai/adk)** | The `gibson` CLI and the component scaffold. Scaffold, build, validate, check in, submit missions | Apache-2.0 |
| **[`setec`](https://github.com/zeroroot-ai/setec)** | Standalone microVM operator. Kata/Firecracker sandboxes — the untrusted-code execution boundary. Useful on its own, with or without Gibson | Apache-2.0 |
| **[`charts`](https://github.com/zeroroot-ai/charts)** | The install chart. One versioned OCI umbrella: CRDs, operators, workloads. The chart is open; the images it pulls need a registry credential | Apache-2.0 |
| **[`gibson`](https://github.com/zeroroot-ai/gibson)** | The platform. Daemon, ext-authz, both operators, the SPIFFE/JWKS sidecar, the graph and the brain | Elastic v2 |
| **[`dashboard`](https://github.com/zeroroot-ai/dashboard)** | The console. Next.js, Server-Action auth, ConnectRPC over Envoy and SPIFFE mTLS | Elastic v2 |
| **[`gibson-executor`](https://github.com/zeroroot-ai/gibson-executor)** | The in-guest execution agent. Runs security tooling and the MCP bridge inside a Setec microVM | Elastic v2 |

The ADK is the public entry point. What you write with it is yours, with no
obligation back to us. Gibson Runtime and Gibson Console are Elastic License
2.0. Details: [licensing](https://docs.zeroroot.ai/docs/security/licensing).

---

## Stack

| Layer | Technology |
|---|---|
| Languages | Go 1.26, TypeScript 5.9, Python |
| Web | Next.js, React, Tailwind, Shadcn UI |
| RPC | gRPC + Protocol Buffers, Buf |
| Identity | SPIFFE/SPIRE in the cluster. Ed25519 capability grants off the cluster. Zitadel OIDC |
| Authorization | OpenFGA (Zanzibar model) |
| Mission definition | CUE |
| Execution environment | Firecracker + Kata, via Setec |
| Knowledge graph | Neo4j |
| Secrets | OpenBao |
| Observability | OpenTelemetry from the platform. The chart ships no monitoring stack — it is a guest on your cluster and hooks into what you already run |
| Deployment | Kubernetes, Helm, one versioned OCI umbrella chart |

---

<div align="center">

**[Read the security docs →](https://docs.zeroroot.ai/docs/security)** · **[Get the ADK →](https://github.com/zeroroot-ai/adk)** · **[Join Discord](https://discord.gg/mkqd6mU3)**

</div>
