<div align="center">

```
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║  ███████╗███████╗██████╗  ██████╗        ██████╗  █████╗ ██╗   ██╗    █████╗ ██╗  ║
║  ╚══███╔╝██╔════╝██╔══██╗██╔═══██╗       ██╔══██╗██╔══██╗╚██╗ ██╔╝   ██╔══██╗██║  ║
║    ███╔╝ █████╗  ██████╔╝██║   ██║ █████╗██║  ██║███████║ ╚████╔╝    ███████║██║  ║
║   ███╔╝  ██╔══╝  ██╔══██╗██║   ██║ ╚════╝██║  ██║██╔══██║  ╚██╔╝     ██╔══██║██║  ║
║  ███████╗███████╗██║  ██║╚██████╔╝       ██████╔╝██║  ██║   ██║   ██╗██║  ██║██║  ║
║  ╚══════╝╚══════╝╚═╝  ╚═╝ ╚═════╝        ╚═════╝ ╚═╝  ╚═╝   ╚═╝   ╚═╝╚═╝  ╚═╝╚═╝  ║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
```

# Security R&D to production. Same day. Same safety.

**Gibson is the platform where new security capabilities become production-worthy on day one.**

[![Discord](https://img.shields.io/badge/Discord-Join_Community-7289DA?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/mkqd6mU3)
[![Email](https://img.shields.io/badge/Contact-anthony@zero--day.ai-red?style=for-the-badge&logo=gmail&logoColor=white)](mailto:anthony@zero-day.ai)

</div>

---

## The problem Gibson solves

Security moves at research speed. New tools, new techniques, new agents drop every week. Your team wants to run the thing they read about Monday morning in production by Friday.

Today, they can't:

- **Run it on a laptop.** Fast. Invisible to the SOC. Zero governance. Not production.
- **Wait for the platform team.** Six months per tool: isolation, identity, audit, networking, secrets, findings pipeline, ticketing, observability. By the time it ships, the window has closed.
- **Buy a vendor tool.** You get *their* tool, *their* opinions, *their* roadmap. When your team needs capability #2, start over.

**Gibson is the fourth option: a substrate, not a tool.** Opinionated about the boring parts — isolation, identity, authorization, knowledge graph, observability — because those should be uniform across every capability you ship. Flexible where it matters: your team builds exactly the agent, tool, or plugin they need. Production-worthy on arrival, because the substrate already is.

---

## What "production-worthy on day one" actually means

When a new agent or tool lands in Gibson, the substrate gives it:

- **Hardware-isolated execution.** Tools run inside Firecracker microVMs orchestrated by [Setec](https://github.com/zero-day-ai/setec). Untrusted code, LLM-generated payloads, novel binaries — none of them can escape the VM boundary.
- **Workload identity by default.** Every component in the cluster gets a SPIFFE SVID. Every internal hop is mTLS, pinned to a known peer identity. There is no "internal network we trust."
- **Fine-grained authorization.** OpenFGA backs every authz decision; the registry is generated from proto annotations, not hand-edited. A compromised or prompt-injected agent cannot exceed its grants.
- **Multi-tenant by construction.** Per-tenant Postgres role, per-tenant Neo4j database, per-tenant secret resolution, per-tenant component registry. Not retrofitted.
- **Knowledge graph integration.** Findings, hosts, services, and attack chains land as typed nodes in a shared graph the rest of your fleet — and your dashboard chat assistant — can query. No per-tool ingestion code.
- **Compliance-mapped output.** Every finding maps to MITRE ATT&CK / ATLAS, with optional NIST AI RMF, CIS, and SOC2 overlays. Export as SARIF, JSON, CSV, or HTML.
- **Audit, tracing, and LLM observability.** OpenTelemetry traces and Prometheus metrics for everything; Langfuse for every LLM call. Streamable to your existing stack.

Your team writes the interesting part. The substrate handles the rest.

---

## Zero-trust, end to end

Gibson is built on a strict zero-trust posture. The architecture is the differentiator:

- **No service trusts another service's word.** The daemon validates *no* JWTs itself — every authorization decision is delegated to a dedicated `ext-authz` service over SPIFFE-pinned mTLS.
- **No service trusts the network.** Envoy ↔ ext-authz ↔ daemon channels are all pinned to known SPIFFE peer identities. Plain TCP between platform components is rejected at startup.
- **No component trusts headers it didn't earn.** Identity headers handed to the daemon are emitted by ext-authz only after JWT, FGA, and tenancy claims have all been cross-verified — and the daemon refuses to bind anywhere but loopback if SPIFFE material is missing.
- **No agent trusts the agent next to it.** Tool execution runs in a separate sandbox process over mTLS. Agents talk to tools through capability-grant JWTs, not shared credentials.
- **The dashboard never gets a direct daemon channel.** A CI gate fails the build if any code path opens one — every byte goes through Envoy and ext-authz.

The result: a platform where a compromised tool, a prompt-injected agent, or a leaked credential has a tightly bounded blast radius.

---

## How the pieces fit

| Layer | What it is | What it gives your team |
|---|---|---|
| **SDK** | Public Go SDK for agents, tools, and discovery extractors | Build new capabilities against a stable, versioned, proto-first interface. No model lock-in — declare LLM slot requirements, the framework picks the model. |
| **Daemon** | Multi-tenant control plane for missions, agents, tools, and findings | Mission planning, sub-agent delegation, three-tier memory (working / mission / long-term), graceful checkpointing, GraphRAG-backed reasoning. |
| **ext-authz** | Envoy external authorization service | The platform's sole authz decision point. Every RPC checked against OpenFGA, with capability-grant short-circuits for federated components. |
| **Setec sandbox** | Standalone K8s operator for Firecracker / Kata / gVisor | Sub-100ms cold starts. Every tool invocation hardware-isolated. Useful on its own; Gibson is just one consumer. |
| **Tenant operator** | Kubebuilder operator over `Tenant`, `TenantMember`, `AgentEnrollment`, `ComponentGrant` CRDs | Tenant lifecycle, member invitations, and agent/tool enrollment reconciled declaratively against Zitadel + OpenFGA. |
| **Dashboard** | Next.js 16 / React 19 console | Server-Action authn over Zitadel OIDC, two-layer authorization (UI + server), and a tenant-scoped chat assistant grounded in your knowledge graph. |

---

## Example: a new tool on Monday morning

An analyst reads about a new fuzzer at a conference on Monday. By Tuesday it's running in prod against her own targets.

**Without Gibson:** Platform request Monday. Security review week 3. Identity wiring week 6. Findings pipeline week 10. Prod in month 5. By then the tool is obsolete.

**With Gibson:**

```bash
# Monday 10am — scaffold
gibson-cli plugin init fuzzer-xyz

# Monday 12pm — validate against the manifest schema
gibson-cli plugin validate ./fuzzer-xyz

# Monday 2pm — enroll with the daemon (issues a SPIFFE identity and FGA grants)
gibson-cli plugin enroll ./fuzzer-xyz

# Monday 3pm — ship: helm upgrade picks up the new component
helm upgrade gibson ./helm/gibson --reuse-values
```

Every invocation now runs in a microVM. Findings flow into the knowledge graph. OpenFGA gates who can call it. Audit events stream to your SIEM. OpenTelemetry traces land in your observability stack.

**Same day. Same safety.**

---

## What your team builds on top

Gibson is purpose-built for security work. The agents, tools, and plugins your team would actually ship:

| Domain | Example |
|---|---|
| **Continuous pentest** | Autonomous recon + exploitation chains that adapt to the target |
| **Patch validation** | Apply a candidate patch in a sandbox, re-run the exploit, verify the fix |
| **Vulnerability verification** | Reproduce a CVE against your asset inventory, confirm blast radius |
| **Attack surface management** | Continuous discovery and change detection across internal and external surfaces |
| **LLM red-teaming** | Prompt injection, jailbreak, RAG poisoning, tool-abuse testing against your own AI systems |
| **Compliance evidence** | Automated control validation and evidence collection, auditor-ready |
| **Incident triage** | Log triage, IOC correlation, automated threat hunting |

---

## The SDK in two minutes

```go
package main

import (
    "context"
    sdk "github.com/zero-day-ai/sdk"
    "github.com/zero-day-ai/sdk/agent"
    "github.com/zero-day-ai/sdk/llm"
)

func main() {
    a, _ := sdk.NewAgent(
        sdk.WithName("recon-agent"),
        sdk.WithVersion("1.0.0"),
        sdk.WithTargetTypes("network"),

        // Declare LLM slot requirements — the framework matches a model.
        // No vendor SDK in your binary, no model lock-in.
        sdk.WithLLMSlot("primary", llm.SlotRequirements{
            MinContextWindow: 32000,
            RequiredFeatures: []string{"function_calling"},
        }),

        sdk.WithExecuteFunc(execute),
    )
    sdk.ServeAgent(a)
}

func execute(ctx context.Context, h agent.Harness, task agent.Task) (agent.Result, error) {
    // Reason with the LLM the framework provisioned for you.
    resp, _ := h.Complete(ctx, "primary", []llm.Message{
        {Role: llm.RoleSystem, Content: "You are a security analyst."},
        {Role: llm.RoleUser, Content: task.Goal},
    })

    // Call a tool. Inside a microVM. Scoped to this agent's capability grants.
    // Wire format is resolved at runtime via FileDescriptorSet — no proto imports.
    var out fuzzerpb.FuzzResponse
    _ = h.CallToolProto(ctx, "fuzzer-xyz", &fuzzerpb.FuzzRequest{Target: task.Goal}, &out)

    // Three tiers of memory: working, mission, long-term graph.
    _ = h.Memory().Working().Set(ctx, "last_completion", resp.Content)

    return agent.NewSuccessResult("done"), nil
}
```

---

## Knowledge graph as native memory

Every entity your agents and tools discover lands in a shared Neo4j graph with typed relationships:

```
┌───────────────────────────────────────────────────────────────────────────┐
│                                                                           │
│   Mission ──[HAS_RUN]──▶ MissionRun ──[CONTAINS_AGENT_RUN]──▶ AgentRun   │
│                                                                           │
│   Host ──[HAS_PORT]──▶ Port ──[RUNS_SERVICE]──▶ Service ──[HAS_ENDPOINT]──▶ Endpoint │
│                                                                           │
│   Domain ──[HAS_SUBDOMAIN]──▶ Subdomain ──[RESOLVES_TO]──▶ Host          │
│                                                                           │
│   Finding ──[AFFECTS]──▶ {Host, Service, Endpoint}                        │
│   Finding ──[HAS_EVIDENCE]──▶ Evidence                                    │
│   Finding ──[USES_TECHNIQUE]──▶ Technique (MITRE ATT&CK / ATLAS)         │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

UUID identity with automatic deduplication. CEL validators on every node type. Taxonomy driven by one YAML file in the SDK — edit it, regenerate, and the proto schema, Go types, graph schema, and query helpers all move together.

---

## Ask your fleet questions

Every Gibson deployment ships with a dashboard chat assistant scoped to your tenant's knowledge graph. Once your team has agents populating the graph, anyone in the org can interrogate it in plain language:

> **CISO:** *"How many critical CVEs are in production right now? Which ones were introduced this week?"*
>
> **Platform engineer:** *"How many services are running in this cluster? Which ones expose endpoints that haven't been scanned in the last 7 days?"*
>
> **SRE:** *"What changed in our external attack surface this week?"*
>
> **Compliance lead:** *"Show me findings mapped to CC6.1 from the last quarter."*

No SQL. No Cypher. No custom dashboards. The assistant reads tenant-scoped graph context, picks the right analyst persona, and streams a grounded answer through the LLM provider you already use. BYOK — no data leaves your perimeter.

**The assistant is only as good as the agents you've deployed.** No agents → empty graph → generic answers. Ship a recon agent → the graph knows your hosts and services. Ship a vulnerability agent → the graph knows your CVEs. Every tool your team wraps adds another dimension the assistant can reason over. *That* is the substrate in action.

**On the roadmap — tool-calling chat.** The assistant moves from reader to dispatcher: *"run recon against 10.0.42.0/24 with the appsec toolkit"* → Gibson kicks off the mission, FGA-gated, tenant-scoped, auditable.

---

## Deployment

A single Helm chart brings the entire stack — daemon, dashboard, Envoy gateway, ext-authz, OpenFGA, SPIRE, Zitadel, Postgres, Redis, Neo4j, Langfuse, and the OpenTelemetry collector — up in one install. Production runs on EKS today and is reconciled by ArgoCD App-of-Apps; the chart is portable to any conformant Kubernetes cluster.

```bash
# kind / dev — full stack, one command
make -C deploy/helm/gibson kind-create deploy-local

# production — managed services for the heavy data planes
helm install gibson ./deploy/helm/gibson -f values-aws-prod.yaml
```

**Roadmap.** Split-plane shapes (managed control plane + customer data plane) and an embedded mode for partners who want Gibson inside their own SaaS. Today the chart deploys the full stack into a single cluster; production overlays inject external Postgres / Redis / Zitadel where you already have them.

---

## Repos

### Public

| Repo | What it is |
|---|---|
| **[`sdk`](https://github.com/zero-day-ai/sdk)** | Public Go SDK for agents, tools, and discovery extractors. BSL 1.1. |
| **[`setec`](https://github.com/zero-day-ai/setec)** | Standalone Kubernetes operator orchestrating Firecracker microVMs via Kata. Apache 2.0. |
| **[`gibson-tool-runner`](https://github.com/zero-day-ai/gibson-tool-runner)** | One microVM image, one Go binary, parsers for nmap, nuclei, naabu, subfinder, httpx, masscan, dnsx, amass. Apache 2.0. |

### Behind the curtain (today)

The daemon, dashboard, ext-authz, tenant-operator, and Helm chart are private during the active build-out. They open as the platform stabilizes — the SDK and the sandbox are public first because that's where the community can build.

---

## Licensing

**Business Source License (BSL 1.1)** for the SDK and platform — converts to Apache 2.0 after 4 years. Same model as HashiCorp, Sentry, CockroachDB, MariaDB. The Setec sandbox and the tool runner are Apache 2.0 today.

| Use case | Tier |
|---|---|
| Bug bounty hunting | Free (keep all rewards) |
| Internal security team | Commercial |
| MSSP / consulting | Commercial |
| Offering as a managed service | Commercial |

[Contact for pricing →](mailto:anthony@zero-day.ai)

---

## Tech stack

| Layer | Technology |
|---|---|
| Languages | Go 1.25, TypeScript 5.9 |
| Web | Next.js 16, React 19, Tailwind 4, Shadcn UI |
| RPC | gRPC + Protocol Buffers, Buf for tooling |
| Workload identity | SPIFFE / SPIRE |
| Authentication | Zitadel (OIDC) |
| Authorization | OpenFGA (Zanzibar relation model), Envoy ext_authz |
| Sandbox | Firecracker + Kata, via the Setec K8s operator |
| Knowledge graph | Neo4j |
| Job queue & streams | Redis Stack |
| Persistence | Postgres (per-tenant roles), per-tenant vector storage |
| LLM providers | Anthropic, AWS Bedrock, OpenAI, Ollama — BYOK |
| Observability | Langfuse, OpenTelemetry, Prometheus |
| Deployment | Kubernetes, Helm, ArgoCD |

---

<div align="center">

## Build the agents your CISO, SRE, and auditor all signed off on.

**[Schedule a demo](mailto:anthony@zero-day.ai?subject=Gibson%20Demo%20Request)** · **[Join Discord](https://discord.gg/mkqd6mU3)**

---

**Zero-Day.ai**

[anthony@zero-day.ai](mailto:anthony@zero-day.ai)

</div>
