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

# The zero-trust agent factory.

**Build any agent. Run it on a substrate that enforces zero trust at every layer.**

Security, ops, compliance, data, internal automation — the platform is domain-agnostic. You bring the agent logic; the substrate brings identity, isolation, grants, memory, and audit. Offsec is one of the example tool bundles, not the boundary.

[![Discord](https://img.shields.io/badge/Discord-Join_Community-7289DA?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/mkqd6mU3)
[![Email](https://img.shields.io/badge/Contact-sales@zeroroot.ai-blue?style=for-the-badge&logo=gmail&logoColor=white)](mailto:sales@zeroroot.ai)

</div>

---

## Build your first agent in 30 minutes

The [ADK](https://github.com/zeroroot-ai/adk) (`gibson` CLI) is designed for AI-assisted development. Scaffold a component, open your AI coding agent (Claude Code, Cursor), describe what you want — the scaffold contains everything the AI needs to write a complete, correct implementation without hand-holding.

```bash
# Install the CLI
go install github.com/zeroroot-ai/adk/cmd/gibson@latest

# One-time workspace setup
gibson init --gibson-url https://api.zeroroot.ai

# Scaffold the component you want to build — any domain
gibson component init slo-checker --kind tool
cd slo-checker

# Open your AI editor — Claude Code, Cursor, whatever you use
claude
```

Then tell your AI what you want:

> *"Build a Gibson tool that queries Prometheus for the SLO burn rate of a list of services and flags any that are over budget. Read AGENTS.md first. Populate the Discovery field so results land in the knowledge graph."*

The AI reads `AGENTS.md` (the component contract baked into the scaffold), writes the proto definition, implements the tool, runs `make proto` and `gibson component validate`, and produces a working binary — without you touching the implementation. Then:

```bash
# Paste the enrollment command from the dashboard
gibson component register --client-id <id> --client-secret - --gibson-url <url>
gibson component run

# That's it. Hardware-isolated, identity-scoped, audit-traced, graph-wired.
```

Every invocation now runs inside a Firecracker microVM. The component's SPIFFE identity gates what else it can call. Everything it discovers lands automatically in the shared knowledge graph. None of that is specific to what your agent actually *does* — a recon scanner, an SLO checker, a compliance-evidence collector, and a data-enrichment tool all get the same guarantees for free.

### What the scaffold gives your AI

`gibson component init` produces a complete directory the AI navigates without prompting:

```
my-tool/
├── AGENTS.md              ← AI contract: interfaces, harness API, proto layout, graph wiring
├── CLAUDE.md              ← Claude Code shortcuts
├── prompts/               ← step-by-step recipes: add-method, add-discovery, debug-enrollment
├── component.yaml         ← kind, name, version
├── main.go                ← serve.Tool(&MyTool{}) stub
├── api/proto/             ← proto definition with field 100 = DiscoveryResult pre-reserved
├── proto/vendor/          ← vendored SDK protos (no config needed)
├── buf.yaml, buf.gen.yaml ← buf v2, STANDARD lint
├── go.mod                 ← pinned to SDK release
├── Makefile               ← proto / build / test / register / run / image
├── Dockerfile             ← distroless, non-root
└── .claude/settings.json  ← AI shell allowlist (make, gibson, buf, go test only)
```

The AI shell allowlist is intentional: Claude can scaffold, build, validate, and register, but cannot `kubectl apply`, `helm install`, or write outside the component directory.

### Three component shapes

| Kind | What it is | Built with |
|------|------------|------------|
| **agent** | LLM-driven gRPC service — reasons, plans, delegates to tools | `sdk.NewAgent` + `serve.Agent` |
| **tool** | Stateless proto-in / proto-out executor, runs in microVM | `serve.Tool` |
| **plugin** | Stateful integration with declared methods and lifecycle | `plugin.Serve` |

Every tool response has **field 100 reserved for `DiscoveryResult`**. Fill it and the daemon's DiscoveryProcessor writes the entries into the knowledge graph automatically. No Cypher, no ingestion pipeline, no extra config.

---

## Why a substrate, not just a framework

Writing an agent is the easy part — an afternoon with an LLM SDK gets you a prototype. *Running* fleets of agents safely is the hard part, and it's the same hard part whether the agent scans networks, reconciles invoices, or triages incidents:

- **Who is this agent, and what is it allowed to touch?**
- **What happens when one gets prompt-injected or simply goes wrong?**
- **How do you see what it did, replay it, and prove it to an auditor?**
- **How do you stop one agent's blast radius from reaching the next?**

Zero Root answers those once, at the substrate, so every agent you build inherits the answers. You write domain logic; you never re-implement identity, isolation, grants, memory tiers, or audit. That's the factory: a repeatable way to turn an idea into a hardened, observable, identity-scoped agent — in any domain.

---

## Gibson: the flagship security brain

The factory's first flagship is **Gibson** — an autonomous security engine. Point it at your environment and it builds a *living model* of how risk actually connects, reasons over it to find the way through, and replays every move. One engine for the team breaking in and the team locking down.

- **A living model of your environment.** Gibson builds one coherent picture as it works: every asset, access path, and exposure it discovers, kept current as the engagement unfolds — not a one-time scan.
- **It thinks in paths, not checklists.** Gibson reasons about how weaknesses chain and where they lead, so you get the handful of paths that are real risk. Offense walks the path; defense cuts it; purple works from one shared picture.
- **Replayable, move by move.** Every engagement is an event-sourced record you can rewind and scrub: exactly what Gibson saw, weighed, and did, fully reproducible. The audit answer, built in.

Gibson puts the substrate to work on the hardest autonomous-security problem — the same identity, isolation, grants, memory, and audit every agent inherits. It's the worked example of what the factory produces; build your own flagship for any domain on the same foundation.

---

## What makes it zero trust, not zero-trust-adjacent

| Principle | How Zeroroot.ai implements it |
|---|---|
| **Verify every identity** | Every component carries a SPIFFE SVID. Every internal hop is mTLS pinned to a known peer. No "trusted internal network." |
| **Grant least privilege explicitly** | OpenFGA capability grants scoped to agent identity. Your PR-review bot cannot call the deploy tool. Your data-export agent cannot reach the billing API. Your red-team agent cannot touch ServiceNow. Every call checked. |
| **Assume breach** | Every tool invocation runs inside a Firecracker microVM via [Setec](https://github.com/zeroroot-ai/setec). A prompt-injected agent cannot reach adjacent tools. A compromised tool cannot escalate to the platform. |
| **Inspect continuously** | OpenTelemetry traces on every hop. Langfuse on every prompt, completion, tool call, and graph write. Full replay of any mission step-by-step. |
| **Minimize blast radius** | Multi-tenant by construction: per-tenant data planes, per-tenant secrets, per-tenant component registry. A breach in one tenant is physically isolated from every other. |

---

## Your agents run where you work

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

**BYOK for LLMs** — keys stay where your team puts them; the platform never custodies them. No model lock-in. **Self-hosted Enterprise** — full stack on your own Kubernetes cluster; same zero-trust guarantees, your perimeter. [Contact sales →](mailto:sales@zeroroot.ai)

---

## Open source SDK + ADK — own what you build

The SDK and ADK are open source (BSL 1.1, converts to Apache 2.0 after 4 years). Your team builds against a stable, versioned, proto-first interface they can read, fork, and extend.

```go
import (
    sdk "github.com/zeroroot-ai/sdk"
    "github.com/zeroroot-ai/sdk/agent"
    "github.com/zeroroot-ai/sdk/llm"
)

func execute(ctx context.Context, h agent.Harness, task agent.Task) (agent.Result, error) {
    // Declare LLM slot requirements at build time.
    // The platform picks the model at runtime — no model lock-in, no vendor SDK in your binary.
    resp, _ := h.Complete(ctx, "primary", []llm.Message{
        {Role: llm.RoleSystem, Content: "You are a helpful analyst."},
        {Role: llm.RoleUser,   Content: task.Goal},
    })

    // Call another tool. Scoped by FGA grants. Runs in its own microVM.
    var out scanpb.ScanResponse
    _ = h.CallToolProto(ctx, "my-tool", &scanpb.ScanRequest{Target: task.Goal}, &out)

    // Three memory tiers: working (this run), mission (shared across agents), graph (permanent).
    _ = h.Memory().Working().Set(ctx, "result", resp.Content)

    return agent.NewSuccessResult("done"), nil
}
```

What you don't write: transport, identity, secrets, mTLS setup, observability init, FGA check calls, graph ingestion, microVM orchestration. The substrate handles all of it — regardless of domain.

---

## Knowledge graph as shared memory

Every discovery your agents make lands in a shared Neo4j graph with typed relationships. What one agent learns, the next one starts from.

**The taxonomy is yours.** The graph is defined by a single source-of-truth taxonomy in the SDK (`taxonomy/core.yaml`) — node types, properties, enums, relationships, and validation rules. `taxonomy-gen` compiles it into the proto, Go types, graph schema, CEL validators, and query helpers all at once, so the whole stack moves together when you change it. The platform ships a security-domain taxonomy as a worked example:

```
Mission ──[HAS_RUN]──▶ MissionRun ──[CONTAINS_AGENT_RUN]──▶ AgentRun   (domain-agnostic core)

# ── example: the bundled security schema ──
Host ──[HAS_PORT]──▶ Port ──[RUNS_SERVICE]──▶ Service ──[HAS_ENDPOINT]──▶ Endpoint
Domain ──[HAS_SUBDOMAIN]──▶ Subdomain ──[RESOLVES_TO]──▶ Host
Finding ──[AFFECTS]──▶ {Host, Service, Endpoint}
Finding ──[HAS_EVIDENCE]──▶ Evidence
Finding ──[USES_TECHNIQUE]──▶ Technique
```

Swap those entity types for `Invoice`, `Incident`, `Control`, `Dataset` — whatever your domain models. UUID deduplication and CEL validators apply to every node type you define.

### Customize the taxonomy for your company

You don't fork the base taxonomy to make it yours — you **extend** it. Layer a `TaxonomyExtension` with your own node types, relationships, properties, and rules on top of the core, and they compose into one coherent graph. Every type carries its provenance: the registry's `NodeTypeSource` tells you whether a given type came from the Gibson core or from *your* extension, so upgrades to the base never silently clobber your model and your additions never get mistaken for platform defaults.

```go
ext := graphrag.TaxonomyExtension{
    NodeTypes: []graphrag.NodeTypeDefinition{
        {Name: "vendor",   Category: "asset",    Description: "A third-party vendor in scope"},
        {Name: "contract", Category: "evidence", Description: "A signed agreement with a vendor"},
    },
    Relationships: []graphrag.RelationshipDefinition{
        {Name: "GOVERNED_BY", FromTypes: []string{"vendor"}, ToTypes: []string{"contract"}},
    },
}
```

This makes the platform fit how *your* organization actually thinks:

- **Your own entity model** — model the nouns your business cares about (`Vendor`, `Asset`, `Account`, `Patient`, `Shipment`) and the edges between them, not a generic schema you bend to fit.
- **Your own classification scheme** — finding categories, severity ladders, risk tiers, asset criticality: define the enums and ontology your teams already use, and the validators enforce them on every write.
- **Your own compliance frameworks** — the taxonomy ships a compliance-rules layer (`compliance_rules.yaml`); point it at the control sets you report against (SOC 2, ISO 27001, your internal policy catalog) and findings map to *your* controls automatically.
- **One regenerate, everything moves** — edit the YAML or register the extension, run `taxonomy-gen`, and the proto, Go types, graph schema, validators, and the dashboard's natural-language graph queries all update in lockstep. No drift between layers.

The result: every agent your company builds speaks your company's vocabulary, and the shared graph reflects your domain — not ours.

---

## Ask your fleet questions

Every deployment ships a dashboard chat assistant scoped to your tenant's graph. Once your agents are running, ask in plain language — the questions follow whatever your agents put in the graph:

> *"Which services are over their SLO burn-rate budget right now?"*
>
> *"What changed in our external surface overnight?"*
>
> *"Show me everything tagged for SOC 2 CC6.1 from the last quarter."*
>
> *"Which records did the enrichment agents fail on this week, and why?"*

No SQL. No Cypher. BYOK — nothing leaves your perimeter. **On the roadmap:** tool-calling chat — *"kick off the nightly reconciliation run, scoped to the EU tenant"* → mission kicked off, scoped, audited, tenant-bounded.

---

## Public repos

| Repo | What it is | License |
|---|---|---|
| **[`sdk`](https://github.com/zeroroot-ai/sdk)** | Go SDK for agents, tools, plugins. Contracts, harness API, LLM slots, graph wiring. | BSL 1.1 |
| **[`adk`](https://github.com/zeroroot-ai/adk)** | `gibson` CLI — scaffold, build, validate, enroll, submit missions. AI-coder ergonomics baked in. | BSL 1.1 |
| **[`setec`](https://github.com/zeroroot-ai/setec)** | Kubernetes operator for Firecracker microVMs via Kata. Useful standalone. | Apache 2.0 |
| **[`gibson-tool-runner`](https://github.com/zeroroot-ai/gibson-tool-runner)** | An example tool bundle — one microVM image with nmap, nuclei, naabu, subfinder, httpx, masscan, dnsx, amass parsers. Build your own bundle for any domain. | Apache 2.0 |

The control plane, dashboard, and platform charts open as the platform stabilizes — SDK and ADK are public first because that's where teams build.

---

## Two ways to run

- **Managed SaaS** — sign up, `gibson init --gibson-url https://api.zeroroot.ai`, ship. Two-week free trial.
- **Self-hosted — Enterprise** — the full stack on your own Kubernetes cluster. BYO Postgres, Redis, identity provider. Same zero-trust guarantees; your perimeter. [Contact sales →](mailto:sales@zeroroot.ai)

---

## Licensing

BSL 1.1 converts to Apache 2.0 after 4 years. Same model as HashiCorp, Sentry, CockroachDB. Setec and the tool runner are Apache 2.0 today.

| Use case | Tier |
|---|---|
| Independent research / OSS projects | Free |
| Internal team (any domain) | Commercial |
| Service provider / reselling | Commercial |

---

## Tech stack

| Layer | Technology |
|---|---|
| Languages | Go 1.25, TypeScript 5.9 (Rust + Python SDKs in progress) |
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

## Your agents. Any domain. Zero-trust substrate.

**[Build with the SDK →](https://github.com/zeroroot-ai/sdk)** · **[Get the ADK →](https://github.com/zeroroot-ai/adk)** · **[Schedule a demo](mailto:sales@zeroroot.ai?subject=Zeroroot.ai%20Demo)** · **[Join Discord](https://discord.gg/mkqd6mU3)**

---

**Zeroroot.ai** — the zero-trust agent factory

</div>
