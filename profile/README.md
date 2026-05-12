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

**Gibson is the substrate where your team builds the security agents, tools, and missions they actually want — and ships them on day one.**

[![Discord](https://img.shields.io/badge/Discord-Join_Community-7289DA?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/mkqd6mU3)
[![Email](https://img.shields.io/badge/Contact-sales@zero--day.ai-red?style=for-the-badge&logo=gmail&logoColor=white)](mailto:sales@zero-day.ai)

</div>

---

## The problem Gibson solves

Security moves at research speed. New tools, new techniques, new agents drop every week. Your team wants to run the thing they read about Monday morning in production by Friday.

Today, they can't:

- **Run it on a laptop.** Fast. Invisible to the SOC. Zero governance. Not production.
- **Wait for the platform team.** Six months per tool: isolation, identity, audit, networking, secrets, findings pipeline, ticketing, observability. By the time it ships, the window has closed.
- **Buy a vendor tool.** You get *their* tool, *their* opinions, *their* roadmap. When your team needs capability #2, start over.

**Gibson is the fourth option: a substrate, not a tool.** Opinionated about the boring parts — isolation, identity, knowledge graph, observability — so those stay uniform across every capability your team ships. Flexible where it matters: you build exactly the agent, tool, or plugin your workflow needs. Production-worthy on arrival, because the substrate already is.

---

## Where your agents run

Your team writes the agents. They run where you work — laptop, CI, VPS, your own Kubernetes — and dial out to `api.zero-day.ai` for orchestration, shared memory, and the knowledge graph. Your team decides what crosses the wire and what stays on the host. **BYOK** for LLM keys: Anthropic, OpenAI, Bedrock, Gemini, Ollama. No model lock-in.

Untrusted payloads, LLM-generated code, and novel binaries detonate inside [Setec](https://github.com/zero-day-ai/setec) microVMs. Hardware isolation, not containers.

```
 EXECUTION PLANE                 │  CONTROL PLANE · api.zero-day.ai
 ┌──────────────────┐            │  ┌─────────────────────────┐
 │ ● your agent     │            │  │ ● orchestration         │
 │   runs on:       │  ═══════►  │  │ ● shared memory + graph │
 │   laptop · ci ·  │   gRPC     │  │ ● observability         │
 │   vps · k8s      │            │  │ ● sandbox (Setec)       │
 └────────┬─────────┘            │  └─────────────────────────┘
          │
          ▼
 ● BYOK → anthropic · openai · bedrock · gemini · ollama
```

Enterprise customers can self-host the whole stack on their own Kubernetes cluster under a separate agreement — same substrate, same guarantees. [Contact sales →](mailto:sales@zero-day.ai)

---

## What "production-worthy on day one" actually means

When a new agent or tool lands in Gibson, the substrate gives it:

- **Hardware-isolated execution.** Every tool invocation runs inside a Firecracker microVM via [Setec](https://github.com/zero-day-ai/setec). Untrusted code, LLM-generated payloads, and novel binaries cannot escape the VM boundary.
- **Workload identity by default.** Every component gets a verifiable identity; every internal hop is mTLS pinned to a known peer. There is no "internal network we trust."
- **Scoped capabilities, not shared credentials.** Agents, users, teams, and tools each carry their own grants. Your PR-review bot can't touch production; your red-team agent can't touch ServiceNow. Every action audited.
- **Multi-tenant by construction.** Per-tenant data planes, per-tenant secrets, per-tenant component registry. Not retrofitted.
- **Knowledge graph integration.** Findings, hosts, services, attack chains — every discovery lands as a typed node in a shared Neo4j graph the rest of your fleet (and your dashboard chat assistant) can query. No per-tool ingestion code.
- **Compliance-mapped output.** Every finding maps to MITRE ATT&CK / ATLAS, with optional NIST AI RMF, CIS, and SOC2 overlays. Export as SARIF, JSON, CSV, or HTML.
- **Audit, tracing, and LLM observability.** OpenTelemetry traces and Prometheus metrics for everything. Langfuse for every prompt, completion, tool call, and graph write. Replay any mission step-by-step.

Your team writes the interesting part. The substrate handles the rest.

---

## A tightly bounded blast radius

Gibson assumes things will go wrong — a tool will misbehave, an agent will get prompt-injected, a credential will leak. The substrate is designed so none of that becomes a platform-level incident:

- **A compromised tool can't reach the tool next to it.** Tool execution lives in its own microVM and talks to agents over mTLS, not shared filesystems or shared credentials.
- **A prompt-injected agent can't exceed its grants.** Capability checks happen on every call, scoped to the agent's identity. No "the agent asked nicely" path.
- **A leaked LLM key only burns that key.** BYOK means keys live where your team puts them; the platform never custodies them.
- **A misbehaving plugin can't lie about who it is.** Every component proves its identity on connect, before any work is dispatched.
- **A breached web session can't pivot to the data plane.** The dashboard never has a direct channel to the control plane — that boundary is enforced at build time, not by convention.

---

## What you ship with

| Surface | What it is | What it gives your team |
|---|---|---|
| **ADK** | Agent, Tool, and Plugin contracts in a public Go SDK | Build new capabilities against a stable, versioned, proto-first interface. Declare LLM slot requirements; the framework picks the model. Rust and Python in the works. |
| **`gibson` CLI** | Scaffolds projects, installs agents and tools, submits missions, inspects graph state | The client your team scripts against `api.zero-day.ai`. |
| **Missions** | CUE-typed DAGs of agent + tool nodes wired by edges and parameterized by target | CUE catches misconfigurations at submit time — wrong agent name, missing field, bad enum — before the orchestrator runs a step. Pausable, resumable, checkpointed. |
| **Knowledge graph** | Every discovery — hosts, ports, findings, techniques, attack chains — typed in Neo4j under a YAML-driven taxonomy with CEL-validated schemas | What one agent learns, the next one starts from. |
| **Dashboard** | A web console with tenant-scoped chat grounded in your graph, mission monitoring, RBAC, and full LLM trace replay | The view across everything your agents have done — and a place to ask plain-language questions about your fleet. |
| **Sandbox** | [Setec](https://github.com/zero-day-ai/setec) — sub-100ms cold-start microVMs via Firecracker + Kata | Hardware isolation for every tool invocation. Open-source. Useful on its own; Gibson is just one consumer. |

---

## Example: a new tool on Monday morning

An analyst reads about a new fuzzer at a conference on Monday. By Tuesday it's running in prod against her own targets.

**Without Gibson:** Platform request Monday. Security review week 3. Identity wiring week 6. Findings pipeline week 10. Prod in month 5. By then the tool is obsolete.

**With Gibson:**

```bash
# Monday 10am — scaffold from a template (manifest + stub against the SDK)
gibson component init fuzzer-xyz

# Monday 11am — implement, compile the binary, validate the manifest
cd fuzzer-xyz && go build ./... && gibson component validate

# Monday 2pm — enroll: the dashboard wizard issues an enrollment command;
# pasting it locally mints workload identity + scoped grants on the substrate.
gibson component register \
  --client-id "$CLIENT_ID" \
  --client-secret "$CLIENT_SECRET" \
  --gibson-url "$GIBSON_URL"

# Monday 3pm — submit a mission that uses it
gibson mission submit missions/fuzz.yaml --target example.com
```

Every invocation now runs in a microVM. Findings flow into the knowledge graph. Scoped grants gate who can call it. Audit events stream to your SIEM. OpenTelemetry traces land in your observability stack.

**Same day. Same safety.**

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

    // Call a tool. Inside a microVM. Scoped to this agent's grants.
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
│   Mission ──[HAS_RUN]──▶ MissionRun ──[CONTAINS_AGENT_RUN]──▶ AgentRun    │
│                                                                           │
│   Host ──[HAS_PORT]──▶ Port ──[RUNS_SERVICE]──▶ Service                   │
│   Service ──[HAS_ENDPOINT]──▶ Endpoint                                    │
│                                                                           │
│   Domain ──[HAS_SUBDOMAIN]──▶ Subdomain ──[RESOLVES_TO]──▶ Host           │
│                                                                           │
│   Finding ──[AFFECTS]──▶ {Host, Service, Endpoint}                        │
│   Finding ──[HAS_EVIDENCE]──▶ Evidence                                    │
│   Finding ──[USES_TECHNIQUE]──▶ Technique (MITRE ATT&CK / ATLAS)          │
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

**On the roadmap — tool-calling chat.** The assistant moves from reader to dispatcher: *"run recon against 10.0.42.0/24 with the appsec toolkit"* → Gibson kicks off the mission, scoped, audited, tenant-bounded.

---

## Two ways to run

- **Managed SaaS** — the default. Sign up, point your agents at `api.zero-day.ai`, ship. Two-week free trial on every account.
- **Self-hosted — Enterprise only.** Not available out of the box: the Helm chart and production overlays ship to Enterprise customers under a separate agreement. One install brings the whole stack up on any conformant Kubernetes cluster, with BYO Postgres, Redis, and identity provider. [Contact sales →](mailto:sales@zero-day.ai)

```bash
# managed — the path for everyone else
gibson login
```

**Roadmap.** Split-plane shapes (managed control plane + customer data plane) and an embedded mode for partners who want Gibson inside their own SaaS.

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

## Public repos

| Repo | What it is |
|---|---|
| **[`sdk`](https://github.com/zero-day-ai/sdk)** | Public Go SDK for agents, tools, and discovery extractors. BSL 1.1. |
| **[`adk`](https://github.com/zero-day-ai/adk)** | The `gibson` CLI — scaffold, build, enroll, submit missions. BSL 1.1. |
| **[`setec`](https://github.com/zero-day-ai/setec)** | Standalone Kubernetes operator orchestrating Firecracker microVMs via Kata. Apache 2.0. Useful on its own. |
| **[`gibson-tool-runner`](https://github.com/zero-day-ai/gibson-tool-runner)** | One microVM image, one Go binary, parsers for nmap, nuclei, naabu, subfinder, httpx, masscan, dnsx, amass. Apache 2.0. |

The control plane, dashboard, and platform charts are private during the active build-out. They open as the platform stabilizes — the SDK and the sandbox are public first because that's where the community can build.

---

## Licensing

**Business Source License (BSL 1.1)** for the SDK and platform — converts to Apache 2.0 after 4 years. Same model as HashiCorp, Sentry, CockroachDB, MariaDB. The Setec sandbox and the tool runner are Apache 2.0 today.

| Use case | Tier |
|---|---|
| Bug bounty hunting | Free (keep all rewards) |
| Internal security team | Commercial |
| MSSP / consulting | Commercial |
| Offering as a managed service | Commercial |

[Contact for pricing →](mailto:sales@zero-day.ai)

---

## Tech stack

| Layer | Technology |
|---|---|
| Languages | Go 1.25, TypeScript 5.9 (Rust and Python SDKs in the works) |
| Web | Next.js 16, React 19, Tailwind 4, Shadcn UI |
| RPC | gRPC + Protocol Buffers, Buf for tooling |
| Mission DSL | CUE |
| Sandbox | Firecracker + Kata, via the Setec K8s operator |
| Knowledge graph | Neo4j |
| Job queue & streams | Redis Stack |
| LLM providers | Anthropic, AWS Bedrock, OpenAI, Gemini, Ollama — BYOK |
| Observability | Langfuse, OpenTelemetry, Prometheus |
| Deployment | Kubernetes, Helm |

---

<div align="center">

## Build the agents your CISO, SRE, and auditor all signed off on.

**[Schedule a demo](mailto:sales@zero-day.ai?subject=Gibson%20Demo%20Request)** · **[Join Discord](https://discord.gg/mkqd6mU3)**

---

**Zero-Day.ai**

[sales@zero-day.ai](mailto:sales@zero-day.ai)

</div>
