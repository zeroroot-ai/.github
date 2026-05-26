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

# The zero-trust substrate for security agents.

**Every identity proven. Every capability explicitly granted. Every execution isolated. Every discovery shared.**

[![Discord](https://img.shields.io/badge/Discord-Join_Community-7289DA?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/mkqd6mU3)
[![Email](https://img.shields.io/badge/Contact-sales@zeroroot.ai-blue?style=for-the-badge&logo=gmail&logoColor=white)](mailto:sales@zeroroot.ai)

</div>

---

## Two organizations. One mission.

**Zeroroot.ai** is the platform — a zero-trust substrate where security teams build, deploy, and run AI agents, tools, and missions. Zero trust isn't a feature here; it's the architecture. Every component proves its identity on connect. Every capability is explicitly granted. Every execution is hardware-isolated. Every discovery is audited and shared across the knowledge graph.

**[Zero-Day.ai Labs](https://zero-day.ai)** is the research and consulting arm. The Labs team stays at the forefront of AI and LLM security research so that organizations can fight AI threats with AI of their own. They build custom agents and tools deployed on the Zeroroot.ai platform for organizations that need a partner, not just a product — handling the research, the custom development, and the threat intelligence that keeps the platform's threat models current.

Together: **the platform you deploy on, backed by the team that hunts on it.**

---

## What makes it zero trust, not zero-trust-adjacent

Most platforms call their network policy "zero trust." Zeroroot.ai bakes zero trust into the agent execution model itself.

| Principle | How Zeroroot.ai implements it |
|---|---|
| **Verify every identity** | Every component — agent, tool, plugin, dashboard session, operator — carries a SPIFFE SVID. Every internal hop is mTLS pinned to a known peer. No "internal network we trust." |
| **Grant least privilege explicitly** | OpenFGA-backed capability grants scoped to agent identity. Your PR-review bot cannot call the production exploit tool. Your red-team agent cannot touch ServiceNow. Every call checked, every call audited. |
| **Assume breach** | Hardware isolation by default. Every tool invocation runs inside a Firecracker microVM via [Setec](https://github.com/zeroroot-ai/setec). A prompt-injected agent cannot reach adjacent tools. A compromised tool cannot escalate to the platform. |
| **Inspect continuously** | OpenTelemetry traces on every hop. Langfuse on every prompt, completion, tool call, and graph write. Full replay of any mission step-by-step. |
| **Minimize blast radius** | Multi-tenant by construction: per-tenant data planes, per-tenant secrets, per-tenant component registry. A breach in one tenant's workload is physically isolated from every other. |

---

## Fighting fire with fire

Modern threats are AI-driven. Attackers iterate faster, chain vulnerabilities in minutes, and operate at a scale no human analyst can match unaided. Defending against AI-powered attacks with manual processes is a losing game.

Zeroroot.ai is built on the premise that the right response is **symmetric** — AI agents that recon, exploit, verify, and hunt at machine speed, under the same security guarantees you'd demand of any production workload.

**Zero-Day.ai Labs** provides the research side of that equation. The Labs team runs offensive AI research — prompt injection, jailbreak campaigns, RAG poisoning, LLM-assisted vulnerability chaining — so that the platform's threat models reflect what attackers actually deploy, not what researchers theorized three years ago. Their findings ship as platform hardening, new detection rules, and purpose-built agents available to every Zeroroot.ai customer.

---

## The substrate in practice

Your team writes the agents. They run where you work — laptop, CI, VPS, your own Kubernetes — and connect to `api.zeroroot.ai` for orchestration, shared memory, and the knowledge graph. Your team decides what crosses the wire and what stays on the host.

```
 EXECUTION PLANE                   │  CONTROL PLANE · api.zeroroot.ai
 ┌────────────────────┐            │  ┌───────────────────────────────┐
 │ ● your agent       │            │  │ ● orchestration + missions    │
 │   runs on:         │  ═══════►  │  │ ● shared knowledge graph      │
 │   laptop · ci ·    │   mTLS     │  │ ● capability grants (FGA)     │
 │   vps · k8s        │   gRPC     │  │ ● observability + audit       │
 └──────────┬─────────┘            │  │ ● sandbox (Setec microVMs)    │
            │                      │  └───────────────────────────────┘
            ▼
 ● BYOK → anthropic · openai · bedrock · gemini · ollama
```

**BYOK for LLMs** — keys live where your team puts them; the platform never custodies them. No model lock-in. **SPIFFE mTLS everywhere** — even the connection from your laptop to the control plane carries a workload identity. **Self-hosted Enterprise option** — full stack on your own Kubernetes cluster; same zero-trust guarantees, your perimeter.

---

## What you ship with

| Surface | What it gives your team |
|---|---|
| **ADK + `gibson` CLI** | Scaffold, build, validate, enroll, and submit missions against the platform. The `gibson` CLI is the client your team scripts. |
| **Agent / Tool / Plugin SDK** | Public Go SDK with proto-first contracts. Declare LLM slot requirements; the framework picks the model. Rust and Python in the works. |
| **Missions** | CUE-typed DAGs of agent and tool nodes parameterized by target. CUE catches misconfigurations at submit time — wrong agent name, missing field, bad enum — before the orchestrator runs a step. Pausable, resumable, checkpointed. |
| **Knowledge graph** | Every discovery — hosts, ports, findings, techniques, attack chains — typed in Neo4j under a YAML-driven taxonomy. What one agent learns, the next one starts from. |
| **Dashboard** | Tenant-scoped chat grounded in your graph, mission monitoring, RBAC, and full LLM trace replay. Ask your fleet questions in plain language. |
| **Sandbox (Setec)** | Sub-100ms cold-start Firecracker microVMs. Hardware isolation for every tool invocation. Open-source. Useful on its own; Gibson is one consumer. |
| **Zero-Day.ai Labs partnership** | Custom agent development, threat intelligence briefings, and LLM/AI security research delivered as platform updates and purpose-built tooling. |

---

## Zero-Day.ai Labs — the research and consulting arm

The Labs team operates at the edge of AI and LLM security:

- **Custom agent development** — Labs engineers build agents, tools, and complete mission libraries tailored to your environment and deployed on your Zeroroot.ai instance.
- **AI/LLM security research** — ongoing offensive research into prompt injection, jailbreak patterns, RAG poisoning, agentic tool-abuse, and LLM-assisted vulnerability chaining. Findings feed the platform's threat models directly.
- **Red-team engagements** — structured assessments of your AI systems, LLM integrations, and agentic pipelines using the same techniques attackers are developing right now.
- **Threat intelligence** — curated intelligence on the AI attack surface: new jailbreak families, real-world agentic exploits, and LLM-specific CVEs tracked and shipped to customers before they become incidents.

**The Labs team doesn't just advise — they ship.** Every engagement produces artifacts (agents, detection rules, updated FGA models, custom tools) deployed into your Zeroroot.ai instance, not a PDF.

[Engage Zero-Day.ai Labs →](mailto:labs@zero-day.ai)

---

## The SDK in two minutes

```go
package main

import (
    "context"
    sdk "github.com/zeroroot-ai/sdk"
    "github.com/zeroroot-ai/sdk/agent"
    "github.com/zeroroot-ai/sdk/llm"
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
    var out fuzzerpb.FuzzResponse
    _ = h.CallToolProto(ctx, "fuzzer-xyz", &fuzzerpb.FuzzRequest{Target: task.Goal}, &out)

    // Three tiers of memory: working, mission, long-term graph.
    _ = h.Memory().Working().Set(ctx, "last_completion", resp.Content)

    return agent.NewSuccessResult("done"), nil
}
```

Every invocation runs in a Firecracker microVM. The agent's SPIFFE identity gates what tools it can call. Every tool call, LLM completion, and graph write is traced and audited. No extra setup — the substrate handles it.

---

## Knowledge graph as shared memory

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   Mission ──[HAS_RUN]──▶ MissionRun ──[CONTAINS_AGENT_RUN]──▶ AgentRun  │
│                                                                          │
│   Host ──[HAS_PORT]──▶ Port ──[RUNS_SERVICE]──▶ Service                 │
│   Service ──[HAS_ENDPOINT]──▶ Endpoint                                  │
│                                                                          │
│   Domain ──[HAS_SUBDOMAIN]──▶ Subdomain ──[RESOLVES_TO]──▶ Host         │
│                                                                          │
│   Finding ──[AFFECTS]──▶ {Host, Service, Endpoint}                      │
│   Finding ──[HAS_EVIDENCE]──▶ Evidence                                  │
│   Finding ──[USES_TECHNIQUE]──▶ Technique (MITRE ATT&CK / ATLAS)        │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

UUID identity with automatic deduplication. CEL validators on every node type. Taxonomy driven by a single YAML file in the SDK — edit it, regenerate, and the proto schema, Go types, graph schema, and query helpers all move together.

---

## Ask your fleet questions

Every deployment ships a dashboard chat assistant scoped to your tenant's knowledge graph:

> *"How many critical CVEs are in production right now? Which ones were introduced this week?"*
>
> *"Which services expose endpoints that haven't been scanned in the last 7 days?"*
>
> *"Show me findings mapped to CC6.1 from the last quarter."*
>
> *"What LLM-assisted attack patterns have our red-team agents detected this month?"*

No SQL. No Cypher. No custom dashboards. BYOK — no data leaves your perimeter. **On the roadmap:** tool-calling chat — *"run recon against 10.0.42.0/24"* → mission kicked off, scoped, audited, tenant-bounded.

---

## Public repos

| Repo | What it is |
|---|---|
| **[`sdk`](https://github.com/zeroroot-ai/sdk)** | Public Go SDK for agents, tools, and discovery extractors. BSL 1.1. |
| **[`adk`](https://github.com/zeroroot-ai/adk)** | The `gibson` CLI — scaffold, build, enroll, submit missions. BSL 1.1. |
| **[`setec`](https://github.com/zeroroot-ai/setec)** | Standalone Kubernetes operator for Firecracker microVMs via Kata. Apache 2.0. |
| **[`gibson-tool-runner`](https://github.com/zeroroot-ai/gibson-tool-runner)** | One microVM image with parsers for nmap, nuclei, naabu, subfinder, httpx, masscan, dnsx, amass. Apache 2.0. |

The control plane, dashboard, and platform charts are private during the active build-out. They open as the platform stabilizes.

---

## Two ways to run

- **Managed SaaS** — sign up, point your agents at `api.zeroroot.ai`, ship. Two-week free trial.
- **Self-hosted — Enterprise** — the full stack on your own Kubernetes cluster under a separate agreement. BYO Postgres, Redis, and identity provider. Same zero-trust guarantees; your perimeter. [Contact sales →](mailto:sales@zeroroot.ai)

---

## Licensing

**Business Source License (BSL 1.1)** for the SDK and platform — converts to Apache 2.0 after 4 years. Setec and the tool runner are Apache 2.0 today.

| Use case | Tier |
|---|---|
| Bug bounty / independent research | Free |
| Internal security team | Commercial |
| MSSP / consulting | Commercial |
| Offering as a managed service | Commercial |
| Custom agent development | [Zero-Day.ai Labs engagement](mailto:labs@zero-day.ai) |

---

## Tech stack

| Layer | Technology |
|---|---|
| Languages | Go 1.25, TypeScript 5.9 (Rust + Python SDKs in the works) |
| Web | Next.js 16, React 19, Tailwind 4, Shadcn UI |
| RPC | gRPC + Protocol Buffers, Buf |
| Identity | SPIFFE/SPIRE, Zitadel OIDC |
| Authorization | OpenFGA (Google Zanzibar model) |
| Mission DSL | CUE |
| Sandbox | Firecracker + Kata via Setec |
| Knowledge graph | Neo4j |
| Job queue | Redis Stack |
| LLM providers | Anthropic, AWS Bedrock, OpenAI, Gemini, Ollama — BYOK |
| Observability | Langfuse, OpenTelemetry, Prometheus |
| Deployment | Kubernetes, Helm |

---

<div align="center">

## Zero trust for the agents that protect you. Zero tolerance for the threats they face.

**[Schedule a platform demo](mailto:sales@zeroroot.ai?subject=Zeroroot.ai%20Demo%20Request)** · **[Engage Zero-Day.ai Labs](mailto:labs@zero-day.ai?subject=Labs%20Engagement)** · **[Join Discord](https://discord.gg/mkqd6mU3)**

---

**Zeroroot.ai** — the platform &nbsp;|&nbsp; **[Zero-Day.ai Labs](https://zero-day.ai)** — the research arm

</div>
