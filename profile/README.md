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

**Build your own agents. Run them on a platform that enforces zero trust at every layer.**

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

# Scaffold the component you want to build
gibson component init prom-scanner --kind tool
cd prom-scanner

# Open your AI editor — Claude Code, Cursor, whatever you use
claude
```

Then tell your AI what you want:

> *"Build a Gibson tool that probes HTTPS endpoints for exposed Prometheus /metrics routes. Read AGENTS.md first. Populate the Discovery field so findings land in the knowledge graph."*

The AI reads `AGENTS.md` (the component contract baked into the scaffold), writes the proto definition, implements the tool, runs `make proto` and `gibson component validate`, and produces a working binary — without you touching the implementation. Then:

```bash
# Paste the enrollment command from the dashboard
gibson component register --client-id <id> --client-secret - --gibson-url <url>
gibson component run

# That's it. Hardware-isolated, identity-scoped, audit-traced, graph-wired.
```

Every invocation now runs inside a Firecracker microVM. The component's SPIFFE identity gates what else it can call. Everything it discovers lands automatically in the shared knowledge graph.

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
        {Role: llm.RoleSystem, Content: "You are a security analyst."},
        {Role: llm.RoleUser,   Content: task.Goal},
    })

    // Call another tool. Scoped by FGA grants. Runs in its own microVM.
    var out scanpb.ScanResponse
    _ = h.CallToolProto(ctx, "my-scanner", &scanpb.ScanRequest{Target: task.Goal}, &out)

    // Three memory tiers: working (this run), mission (shared across agents), graph (permanent).
    _ = h.Memory().Working().Set(ctx, "result", resp.Content)

    return agent.NewSuccessResult("done"), nil
}
```

What you don't write: transport, identity, secrets, mTLS setup, observability init, FGA check calls, graph ingestion, microVM orchestration. The substrate handles all of it.

---

## Fighting fire with fire

Modern threats are AI-driven. Attackers chain vulnerabilities in minutes, iterate at machine speed, and operate at a scale no human analyst can match unaided. Defending with manual processes is a losing game.

Zeroroot.ai is built on the premise that the right response is **symmetric** — your own AI agents that recon, exploit, verify, and hunt at machine speed, under the same security guarantees you'd demand of any production workload.

---

## What makes it zero trust, not zero-trust-adjacent

| Principle | How Zeroroot.ai implements it |
|---|---|
| **Verify every identity** | Every component carries a SPIFFE SVID. Every internal hop is mTLS pinned to a known peer. No "trusted internal network." |
| **Grant least privilege explicitly** | OpenFGA capability grants scoped to agent identity. Your PR-review bot cannot call the production exploit tool. Your red-team agent cannot touch ServiceNow. Every call checked. |
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

## Knowledge graph as shared memory

Every discovery your agents make lands in a shared Neo4j graph with typed relationships. What one agent learns, the next one starts from.

```
Mission ──[HAS_RUN]──▶ MissionRun ──[CONTAINS_AGENT_RUN]──▶ AgentRun

Host ──[HAS_PORT]──▶ Port ──[RUNS_SERVICE]──▶ Service ──[HAS_ENDPOINT]──▶ Endpoint
Domain ──[HAS_SUBDOMAIN]──▶ Subdomain ──[RESOLVES_TO]──▶ Host

Finding ──[AFFECTS]──▶ {Host, Service, Endpoint}
Finding ──[HAS_EVIDENCE]──▶ Evidence
Finding ──[USES_TECHNIQUE]──▶ Technique  (MITRE ATT&CK / ATLAS)
```

UUID deduplication. CEL validators on every node type. Schema driven by a single YAML file in the SDK — edit it, regenerate, and the proto, Go types, graph schema, and query helpers all move together.

---

## Ask your fleet questions

Every deployment ships a dashboard chat assistant scoped to your tenant's graph. Once your agents are running:

> *"How many critical CVEs are in production right now? Which ones appeared this week?"*
>
> *"Which services expose endpoints that haven't been scanned in 7 days?"*
>
> *"What changed in our external attack surface overnight?"*
>
> *"Show me findings mapped to CC6.1 from the last quarter."*

No SQL. No Cypher. BYOK — nothing leaves your perimeter. **On the roadmap:** tool-calling chat — *"run recon against 10.0.42.0/24"* → mission kicked off, scoped, audited, tenant-bounded.

---

## Public repos

| Repo | What it is | License |
|---|---|---|
| **[`sdk`](https://github.com/zeroroot-ai/sdk)** | Go SDK for agents, tools, plugins. Contracts, harness API, LLM slots, graph wiring. | BSL 1.1 |
| **[`adk`](https://github.com/zeroroot-ai/adk)** | `gibson` CLI — scaffold, build, validate, enroll, submit missions. AI-coder ergonomics baked in. | BSL 1.1 |
| **[`setec`](https://github.com/zeroroot-ai/setec)** | Kubernetes operator for Firecracker microVMs via Kata. Useful standalone. | Apache 2.0 |
| **[`gibson-tool-runner`](https://github.com/zeroroot-ai/gibson-tool-runner)** | One microVM image with nmap, nuclei, naabu, subfinder, httpx, masscan, dnsx, amass parsers. | Apache 2.0 |

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
| Bug bounty / independent research | Free |
| Internal security team | Commercial |
| MSSP / managed service | Commercial |

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

## Your agents. Zero-trust substrate. Research-backed defense.

**[Build with the SDK →](https://github.com/zeroroot-ai/sdk)** · **[Get the ADK →](https://github.com/zeroroot-ai/adk)** · **[Schedule a demo](mailto:sales@zeroroot.ai?subject=Zeroroot.ai%20Demo)** · **[Join Discord](https://discord.gg/mkqd6mU3)**

---

**Zeroroot.ai** — the zero-trust substrate for security agents

</div>
