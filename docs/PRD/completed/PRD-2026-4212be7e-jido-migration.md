---
document_id: PRD-2026-4212be7e
label: prd-jido-migration
version: 1.0.1
status: Under Review
date: 2026-08-18
author: Lead Agent (PRD Phase via ensemble:create-prd; refined via ensemble:refine-prd)
total_requirements: 26
scale_depth: STANDARD
readiness_score: 5.0
readiness_gate: PASS
ambiguity_markers: 0
---

# PRD-2026-4212be7e: Jido Agent Ecosystem Migration

## PRD Health Summary

| Metric | Value |
|--------|-------|
| **Total Requirements** | 26 (REQ-001 through REQ-026) |
| **Must** | 24 |
| **Should** | 2 |
| **Could** | 0 |
| **Won't (this release)** | 0 |
| **AC Coverage** | ACs written inline per requirement |
| **Risk Flags** | 3 beta packages requiring mitigation: `jido_mcp`, `jido_live_dashboard`, `jido_workspace` |
| **Cross-Requirement Dependencies** | See Section 8 |
| **Readiness Score** | 5.0 |
| **Ambiguity Markers** | 0 (all resolved) |

---

## 1. Executive Summary

### 1.1 Problem Statement

Foreman has accumulated a custom agent and orchestration backend through multiple iterations. While functional, the backend lacks structure, extensibility, and flexibility. Adding a new action takes approximately four days. Agents cannot communicate with each other, with Foreman, or with operators. Observability into agent reasoning and state is limited.

### 1.2 Solution Overview

Migrate Foreman's agent and orchestration layer entirely to the Jido ecosystem (agentjido/jido). Jido provides a production-grade, OTP-native autonomous agent framework with validated actions (including `Jido.Plan` DAG execution), signal-based inter-agent communication, shell execution, and MCP client integration — all maintained as a living ecosystem. This eliminates the custom backend's accumulated debt and unlocks a 10× speedup in action development (four days to four hours). Foreman's three surviving workflows (`create`, `implement`, `fix`) are thin Jido dispatch wrappers that call Ensemble skills. Ensemble skills own PRD/TRD creation, refinement, and implementation; Foreman owns scheduling, merge gates, and observability. LiteLLM+Langfuse is integrated for capability-based model selection with full trace observability.

### 1.3 Value Proposition

- **10× faster action development:** from ~4 days to ~4 hours per action
- **Inter-agent communication:** agents can coordinate, ask clarifying questions, and delegate sub-tasks via `jido_signal`
- **Agent↔operator communication:** agents can ask questions; operators receive notifications via `jido_signal` dispatch to Foreman inbox
- **Agent↔Foreman communication:** agents emit task events via signals; Foreman projections update accordingly
- **Full observability:** `jido_live_dashboard` (Phoenix LiveDashboard), `jido_otel` (OpenTelemetry traces to Langfuse), and LiteLLM per-call traces
- **Capability-based routing:** LiteLLM `model="auto"` selects the cheapest capable model per task
- **MCP service consumption:** agents can call external MCP servers as Jido actions
- **Reduced maintenance burden:** Jido ecosystem is maintained externally; Foreman focuses on workflow orchestration, scheduling, and merge gates

---

## 2. User Analysis

### 2.1 Primary Users

| Role | Description | Pain Point |
|------|-------------|------------|
| **Developer** | Extends Foreman by authoring new Jido actions and workflows | Current custom backend is hard to extend; adding an action takes days |
| **Operator** | Monitors running agents, approves merge gates, answers agent questions | No visibility into agent reasoning; no communication channel with agents |

### 2.2 Current State

Foreman's custom agent backend handles workflow execution, task state, and tool dispatch. It is functional but architecturally stagnant. The backend is not observable, agents cannot communicate with each other or with operators, and there is no model routing layer.

### 2.3 Desired State

```
Operator approves task
→ Jido agent instantiated for workflow
→ Agent dispatches Ensemble skill (create/implement/fix) with idempotency key
→ Ensemble skill runs with --foreman flag; results written durably before side effects reported
→ Agent can ask operator questions via Signal → operator receives inbox notification
→ Agent can consume external MCP services as actions
→ LiteLLM routes each LLM call to cheapest-capable model
→ jido_otel traces every call to Langfuse; jido_live_dashboard shows agent state
→ Human review gate before any merge
→ On crash, task resumes from last checkpoint with idempotency key reconciliation
```

---

## 3. Goals and Non-Goals

### 3.1 Goals

| ID | Goal | Success Metric |
|----|------|----------------|
| G-1 | Migrate to Jido ecosystem | All three surviving workflows (`create`, `implement`, `fix`) dispatch the correct Ensemble skill |
| G-2 | 10× speedup in new action development | Adding a new action takes ≤4 hours end-to-end |
| G-3 | Remove legacy custom backend | Custom agent/orchestration code is removed; no dual-maintenance |
| G-4 | Enable agent↔agent communication | Agents can send signals to coordinate sub-tasks |
| G-5 | Enable agent↔operator communication | Agents can ask clarifying questions; operators receive inbox notifications |
| G-6 | Enable agent↔Foreman communication | Agents can query task state and emit events; Foreman projections update |
| G-7 | Integrate LiteLLM+Langfuse for model routing | `model="auto"` routes by capability; every call is traced in Langfuse |
| G-8 | Fork critical Jido repos | Foreman maintains forked mirrors of all required Jido packages with pinned revisions |
| G-9 | Full observability | jido_live_dashboard shows agent state; jido_otel traces to Langfuse |
| G-10 | Human review before merge | No automatic merge; merge gate always requires human approval |
| G-11 | Agent MCP service consumption | Agents can call external MCP servers as Jido actions |
| G-12 | Agent skill/command/hook execution | Agents load skills as prompt fragments via Jido.Character; commands as Jido.Action modules; hooks as lifecycle signals + Jido.Action |
| G-13 | Idempotent Ensemble dispatch | No duplicate side effects from crash recovery; durable invocation records with lease |
| G-14 | Hot-loadable workflow format | Operators can define new workflows without rebuilding Foreman |

### 3.2 Non-Goals

- Porting the legacy custom backend to Jido — it is removed, not migrated
- Replacing Ensemble skills — Foreman dispatches them, Ensemble owns their implementation
- Modifying the three removed workflows (everything outside `create`, `implement`, `fix`)
- Replacing the Phoenix LiveView UI in v1 (jido_live_dashboard is additive)
- `jido_runic` for DAG orchestration — `jido_action`'s `Jido.Plan` covers internal agent DAGs
- Rebuilding the legacy backend to establish the 4-day baseline — baseline is user-provided
- Live API variability in the representative action benchmark — mocked services only

---

## 4. Proposed Architecture

### 4.1 Target System

```
┌──────────────────────────────────────────────────────────────┐
│  Operator / Developer                                         │
│  - approves tasks, answers agent questions, reviews merges    │
└────────────────────┬───────────────────────────────────────┘
                     │ Signal dispatch to foreman/inbox topic
                     │ (jido_signal Bus.publish with webhook/http adapter)
┌────────────────────▼───────────────────────────────────────┐
│  Jido Signal Bus (:jido_bus)                                 │
│  - CloudEvents-compliant pub/sub                              │
│  - Topics: foreman/operator, foreman/commands, agents/*      │
│  - Journal: signal replay on restart                         │
└──────┬──────────────────────────────────┬───────────────────┘
       │                                  │
       │ Signal (task events)             │ Signal (operator questions,
       │                                  │ approvals, directives)
┌──────▼──────────────────────────────────▼───────────────────┐
│  Jido Agent (per workflow instance)                           │
│  - cmd/2 loop: action in → agent + directives out            │
│  - jido_signal: pub/sub to bus                               │
│  - jido_action: validated action modules                     │
│  - jido_shell + jido_vfs: shell command execution           │
│  - jido_ai: ReAct/CoT reasoning via req_llm                 │
│  - jido_mcp: consume external MCP services as actions        │
│  - Jido.Plan: internal agent DAG (if needed)                │
│  - jido_harness: Pi session adapter                          │
│    (Jido.Harness.Adapters.Pi) replaces pi-sdk-runner.ts       │
│  - jido_otel: OpenTelemetry span emission                    │
└──────┬─────────────────────────┬────────────────────────────┘
       │ req_llm HTTP calls       │ Ensemble skill dispatch
       │                         │ (--foreman, idempotency key)
┌──────▼───────────┐  ┌─────────▼────────────────────────────┐
│  LiteLLM Gateway  │  │  Ensemble Skills (external)          │
│  (model="auto"    │  │  - ensemble:create-prd → ...         │
│   capability      │  │  - ensemble:fix-issue                │
│   routing)        │  │  - Ensemble owns PR creation;         │
│  - Langfuse trace │  │    Foreman owns merge gate            │
└──────┬───────────┘  └─────────────────────────────────────┘
       │ OpenAI-compatible HTTP
┌──────▼──────────────────────────────────────────────────────┐
│  Foreman Elixir Server                                       │
│  - Subscribes to foreman/* signal topics                     │
│  - Validates and appends authoritative Task/Run/Inbox        │
│    domain events to event store                              │
│  - Human approval gates for merge                            │
│  - Event projectors update read-model projections            │
│  - Jido agents own struct/checkpoint state via jido_ecto    │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Jido Package Roles and Stability

| Package | Role in Foreman | Stability | Risk |
|---------|-----------------|-----------|------|
| `jido` | Core agent runtime; `cmd/2` loop; GenServer supervision | Stable | None |
| `jido_action` | Action modules; `Jido.Plan` DAG execution; AI tool integration | Stable (v2.2.1+) | None |
| `jido_signal` | CloudEvents pub/sub bus; inter-agent, operator, Foreman messaging | Stable (v2.0+) | None |
| `jido_shell` | Shell session lifecycle; command execution on `jido_vfs` | Stable | None |
| `jido_vfs` | Virtual filesystem with sandbox policies | Stable | None |
| `jido_ai` | ReAct/CoT reasoning strategies; LLM integration | Stable | None |
| `jido_harness` | Pi session adapter; replaces `pi-sdk-runner.ts`; provides `Jido.Harness.Session`, `Jido.Harness.Run`, `Jido.Harness.Process` | Stable | None |
| `jido_ecto` | Ecto-backed persistence adapter for Jido runtime state; durable checkpoint storage | Stable | None |
| `req_llm` | HTTP client for LLM APIs; used by jido_ai | Stable | None |
| `jido_otel` | OpenTelemetry tracer bridge; exports to Langfuse | Stable (v1.0.0) | None |
| `jido_mcp` | Consume external MCP servers; pool clients; tool sync to agents | Beta (GitHub-only, v0.1) | [RISK: API may break on minor releases; requires fork + pin] |
| `jido_live_dashboard` | Real-time Phoenix LiveDashboard for agent state | Beta (GitHub-only) | [RISK: Phoenix dependency required; beta API] |
| `jido_workspace` | VFS-backed workspace with artifact lifecycle; sandbox policies | Beta (GitHub-only, ~> 0.1.0) | [RISK: in-memory VFS by default; snapshot semantics evolving; validate worktree binding before production use] |

### 4.3 Communication Paths

| Path | Mechanism | Description |
|------|-----------|-------------|
| Agent → Agent | `Jido.Signal.Bus.publish/3` to `agents/<phase>` topic | Phase handoff signals between agents |
| Agent → Operator | `Bus.publish` to `foreman/operator` topic; dispatch via `{:webhook, url}` or `{:http, ...}` to Foreman inbox API | Agent asks question; operator notified |
| Operator → Agent | `Bus.publish` to `agents/<agent-id>/directive` topic | Operator responds; agent resumes |
| Agent → Foreman | `Bus.publish` to `foreman/commands` topic | Task events emitted; Foreman validates and appends authoritative domain events; only event projectors update read-model projections |
| Foreman → Agent | `Bus.publish` to `agents/<agent-id>/directive` topic | Directives: approve, abort, nudge |

### 4.4 Operator Notification Channel

Operator notifications (agent questions, merge approvals needed) flow through `jido_signal`'s pluggable dispatch adapters. The preferred path:

- Agent publishes to `foreman/operator` topic
- `jido_signal` dispatch adapter delivers to Foreman's Phoenix endpoint (webhook or HTTP)
- Foreman appends an authoritative inbox domain event; the event projector updates the inbox read model; operator sees notification via existing `foreman inbox` command

### 4.5 Jido Applicability Include/Exclude Matrix

| Foreman Subsystem | Jido Replacement | Rationale |
|---|---|---|
| Agent runtime (pi-sdk-runner) | `jido` + `jido_harness` (Pi adapter) | `jido_harness` provides `Jido.Harness.Adapters.Pi` — the direct replacement for Foreman's `createAgentSession()` |
| Action modules (custom tool factories) | `jido_action` | Actions are authored as `Jido.Action` modules |
| Inter-agent communication | `jido_signal` | CloudEvents pub/sub bus |
| Agent↔operator | `jido_signal` dispatch to Foreman inbox | Same bus, different dispatch adapter |
| Task/Run/Inbox state | Foreman event-sourced state (domain events); Jido agents emit signals that Foreman consumes to update projections; `jido_ecto` (Postgres adapter) persists Jido agent/checkpoint state only | Foreman is the authoritative source for Task/Run/Inbox transitions; projections are read models updated from domain events |
| AI reasoning strategies | `jido_ai` + `req_llm` | ReAct/CoT strategies |
| LLM observability | `jido_otel` | OTEL spans to Langfuse |
| Agent dashboards | `jido_live_dashboard` (beta) | Phoenix LiveDashboard integration |
| MCP client | `jido_mcp` (beta) | Consume external MCP servers |
| Skills (prompt fragments) | `Jido.Character` or separate prompt template loader | Skills are prompt fragments, not actions — kept as static templates loaded into agent context |
| Hooks (workspace lifecycle commands) | `jido_signal` lifecycle signals + `jido_action` | Hook triggers publish signals; hook actions subscribe and execute |
| Jido agent/checkpoint state | `jido_ecto` (Postgres adapter) | Persists Jido agent struct, directives, and checkpoint state only |
| VCS abstraction | Unchanged | `VcsBackend` interface; `jido_shell` wraps VCS calls |
| Workflow definition | **New hot-loadable format** (REQ-025) | Operators define workflows without rebuilding Foreman |
| Ensemble skills | Unchanged (external) | Foreman dispatches; Ensemble owns implementation |

### 4.6 Workflow Dispatch Contracts

Each workflow is a thin Jido agent that dispatches one or more Ensemble skills with `--foreman` and an idempotency key.

**`create` workflow:**
```
Task approved → CreateAgent → dispatch ensemble:create-prd (--foreman, key=create-prd-{taskId}-1)
  → dispatch ensemble:refine-prd (--foreman, key=create-prd-{taskId}-2)
  → dispatch ensemble:create-trd (--foreman, key=create-prd-{taskId}-3)
  → dispatch ensemble:refine-trd (--foreman, key=create-prd-{taskId}-4)
  → dispatch ensemble:implement-trd (--foreman, key=create-prd-{taskId}-5)
```
Each step runs in sequence. Next step starts only after previous completes.

**`implement` workflow:**
```
Task approved → ImplementAgent → dispatch ensemble-full-implement-trd (--foreman, key=implement-{taskId}-1)
```

**`fix` workflow:**
```
Task approved → FixAgent → dispatch ensemble:fix-issue (--foreman, key=fix-{taskId}-1)
```

**Merge gate (all workflows):** Ensemble creates PRs; Foreman holds the merge gate. Human approval is required before any branch is merged; agents cannot bypass this gate.

### 4.7 Concept Mapping: Foreman → Jido

| Foreman Concept | Current Implementation | Jido Mapping | Notes |
|---|---|---|---|
| Skills | `src/defaults/skills/*.md` — Pi guidance prompt fragments | `Jido.Character` prompt templates or separate static template loader | Skills are NOT actions; they are prompt fragments loaded into agent context |
| Commands | `pi-sdk-tools.ts` — tool factory functions (`git_status`, `diff_read`, `task_get`, etc.) | `Jido.Action` modules — one action per command | Must be reimplemented as `Jido.Action` behaviours |
| Hooks | `src/lib/project-config.ts` — `afterCreate`, `beforeRun`, `afterRun` shell commands | `jido_signal` lifecycle signals + `Jido.Action` that executes the shell command | Hook trigger → signal published; hook action subscribes and runs |
| Guardrails | Pre-tool hooks wrapping tool factories | `Jido.Action` middleware — pipeline of validation functions before action executes | |
| Pi SDK session | `pi-sdk-runner.ts` — `createAgentSession()` | `jido_harness` + `Jido.Harness.Adapters.Pi` | `Jido.Harness.Session`, `Jido.Harness.Run`, `Jido.Harness.Process` replace Pi session lifecycle |
| Workspace lifecycle | VFS worktree scoped to git worktree | `jido_workspace` (beta; validation spike) or `jido_shell` + `jido_vfs` | Must bind to Foreman's `worktreePath`; sandbox policies must be enforced |

---

## 5. Feature Areas

1. **Jido core runtime integration** — agent lifecycle, `cmd/2` loop, GenServer supervision
2. **Jido harness integration** — `jido_harness` + `Jido.Harness.Adapters.Pi` replaces `pi-sdk-runner.ts`
3. **Jido action authoring** — action modules, AI tool integration
4. **Jido signal communication** — inter-agent, agent↔operator, agent↔Foreman messaging via bus
5. **Jido shell + VFS integration** — command execution, session lifecycle, sandbox policies
6. **jido_workspace evaluation** — validation spike for worktree binding, sandbox enforcement, snapshot semantics
7. **Jido AI strategy integration** — ReAct/CoT via `jido_ai` + `req_llm`
8. **LiteLLM+Langfuse integration** — capability-based model routing, per-call traces
9. **Jido observability** — `jido_live_dashboard`, `jido_otel` traces to Langfuse
10. **Workflow dispatch to Ensemble** — `create`, `implement`, `fix` dispatch Ensemble skills with `--foreman`
11. **Idempotent Ensemble dispatch** — durable invocation records with lease, `started/completed/ambiguous` states
12. **Hot-loadable workflow format** — operators define new workflows without rebuilding Foreman
13. **Merge gate with human review** — no auto-merge; approval required
14. **Resumable task execution** — crash recovery with idempotency key reconciliation
15. **Jido repo mirroring** — fork and pin critical Jido packages
16. **Jido MCP client integration** — agents consume external MCP services as actions
17. **Jido agent/checkpoint state** — durable struct and checkpoint state via `jido_ecto` (Postgres adapter); authoritative Task/Run/Inbox domain events remain in Foreman's event store

---

## 6. Functional Requirements

### REQ-001: Jido Core Runtime and State Ownership

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: foundational replacement; Jido agents own their own struct/checkpoint state via jido_ecto; authoritative Task/Run/Inbox domain events remain Foreman's event store]

Foreman shall replace its custom agent backend with the Jido ecosystem. Jido agents own their own struct and checkpoint state, persisted via `jido_ecto`. Authoritative Task/Run/Inbox domain events remain in Foreman's event store; projections are updated by event projectors only.

- AC-001-1: Given a task is approved, when Foreman starts the workflow, then a supervised Jido agent GenServer is started with the appropriate action set.
- AC-001-2: Given a Jido agent runs, when it calls `cmd/2` with an action, then it returns an updated agent struct and a list of directives.
- AC-001-3: Given a Jido agent crashes, when it restarts via OTP supervision, then it resumes from its last checkpoint stored via `jido_ecto`.
- AC-001-4: Given Foreman boots, when it initializes, then the Jido application loads and the agent supervisor starts under Foreman's supervision tree.
- AC-001-5: Given Foreman needs to persist agent state or checkpoints, when state changes, then it is persisted via `jido_ecto` with a Postgres adapter. Authoritative Task/Run/Inbox transitions are domain events in Foreman's event store, not Jido state.

---

### REQ-002: Jido Action Authoring Framework

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: action validation and AI tool integration]

Foreman shall expose every agent capability as a Jido action module (`Jido.Action`), enabling validated, composable, LLM-callable tools. Commands are authored as `Jido.Action` modules. Skills (prompt fragments) are not actions — they are loaded via `Jido.Character` or a separate prompt template loader.

- AC-002-1: Given a developer writes a new `Jido.Action` module, when the module implements the `Jido.Action` behaviour, then it is automatically available as a callable tool the agent can invoke via `cmd/2`.
- AC-002-2: Given an action receives parameters, when validation fails, then the action returns an error result without executing side effects.
- AC-002-3: Given an action completes, when it returns directives, then the agent receives the updated state and processes the directives.
- AC-002-4: Given a new action is added, when it is tested in isolation, then it achieves at least 85% code coverage and can be exercised without a full agent session.
- AC-002-5: Given a developer defines a hook as an action, when the hook's trigger condition is met, then the action is invoked and its result is delivered as a signal.
---
### REQ-003: Jido Harness Pi Adapter Integration

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: jido_harness Pi adapter API surface must be validated against Foreman's current pi-sdk-runner.ts usage]

Foreman shall replace `pi-sdk-runner.ts` with `jido_harness` using `Jido.Harness.Adapters.Pi`. This provides `Jido.Harness.Session`, `Jido.Harness.Run`, and `Jido.Harness.Process` — replacing the Pi SDK session lifecycle.


- AC-003-1: Given Foreman initializes a workflow session, when it calls `Jido.Harness.run/2` with the Pi adapter, then a `Jido.Harness.Session` is created.
- AC-003-2: Given a harness session is running, when the agent calls a tool, then the tool is resolved through `Jido.Harness.Process` and the result is returned to the agent.

---
### REQ-004: Inter-Agent Communication (Agent↔Agent)
**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: signal delivery guarantees and backpressure]

Foreman shall use `jido_signal` to enable agents to communicate with each other via typed CloudEvents-compliant signals.

- AC-004-1: Given an agent needs to delegate a sub-task, when it publishes a signal to a named topic, then all agents subscribed to that topic receive the signal.
- AC-004-2: Given a signal is published, when the recipient agent is running, then it receives the signal in its input queue and can respond.
- AC-004-3: Given an agent publishes a signal with no subscribers, when the configured missing-subscriber policy is `silent`, then the signal is recorded in the journal without notification. When the policy is `warn`, then a warning is logged. When the policy is `error`, then an error is logged. The policy is set in the Foreman config file and defaults to `warn`.

---

### REQ-005: Agent↔Operator Communication

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: notification delivery and response timeout]

Foreman shall enable agents to send questions and approval requests to operators, and receive responses, using `jido_signal`'s dispatch adapters to route to Foreman's inbox API.

- AC-005-1: Given an agent needs operator input, when it publishes a signal to the `foreman/operator` topic, then the signal is dispatched to the Foreman inbox API and the operator sees the question.
- AC-005-2: Given an operator responds, when the response is submitted to Foreman, then Foreman publishes a response signal to the agent's directive topic and the agent resumes.
- AC-005-3: Given an agent sends an operator question, when the operator does not respond within the timeout configured for that workflow, then the agent logs a warning and the task is marked `blocked`. The timeout is configurable per workflow in the workflow definition.


---
### REQ-006: Agent↔Foreman Communication

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: signal routing between Jido bus and Elixir event bus]

Foreman shall enable agents to query task state, emit events, and receive directives from the Foreman Elixir server via signals on the `foreman/commands` topic.

- AC-006-1: Given an agent emits a task event signal, when Foreman's bus subscriber receives it, then Foreman validates and appends the authoritative domain event; only the event projector updates the task state read-model projection.
- AC-006-2: Given Foreman needs to nudge an agent (e.g., after manual approval), when it publishes a directive signal to the agent's topic, then the agent receives the directive and adjusts its behaviour.
- AC-006-3: Given an agent queries task metadata, when it sends a query signal, then Foreman responds with the current task state signal.

---

### REQ-007: Jido Shell Integration

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: shell session lifecycle and VFS consistency; jido_workspace beta]

Foreman shall use `jido_shell` for predictable command execution and shell session lifecycle on top of `jido_vfs`. `jido_workspace` is a candidate for worktree binding but is beta — its worktree binding and sandbox enforcement must be validated before production use.

- AC-007-1: Given an agent needs to run a shell command, when it calls a shell action, then `jido_shell` executes the command with consistent session semantics and VFS isolation.
- AC-007-2: Given `jido_shell` executes a command, when the command modifies files in the worktree, then the changes are visible to subsequent commands in the same session.
- AC-007-3: Given `jido_workspace` is evaluated for worktree binding (validation spike), when the spike completes, then Foreman either adopts `jido_workspace` with validated sandbox policies or uses `jido_shell` + `jido_vfs` with a custom host-path adapter.
- AC-007-4: Given a shell session is active, when Foreman needs to interrupt it, then the session is terminated cleanly. When the agent restarts, the shell session does not survive; the restarted agent creates a new shell session.

---

### REQ-008: Jido AI Strategy Integration

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: strategy selection and LLM call reliability]

Foreman shall use `jido_ai` strategies (ReAct, Chain-of-Thought) for agent reasoning, with `req_llm` as the HTTP client.

- AC-008-1: Given a Jido agent is configured with a strategy, when it processes an action, then the strategy controls how `cmd/2` processes the loop, including any LLM calls.
- AC-008-2: Given an LLM call fails or times out via `req_llm`, when the error propagates, then the agent receives an error directive and can retry or escalate.
- AC-008-3: Given a strategy makes an LLM call, when LiteLLM is configured, then the call is routed through the LiteLLM gateway with `model="auto"` for capability-based routing.

---

### REQ-009: LiteLLM+Langfuse Integration

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: routing configuration and budget management]

Foreman shall integrate the existing LiteLLM+Langfuse stack (`~/Development/Sunstone/litellm-langfuse-stack/`) for model routing and observability.

- AC-009-1: Given a Jido agent makes an LLM call, when `model="auto"` is requested, then LiteLLM routes to the cheapest capable model based on capability filters.
- AC-009-2: Given LiteLLM routes a request, when the request completes, then the trace (prompt, response, model, cost, latency) is logged to Langfuse.
- AC-009-3: Given a user has exhausted their per-model budget, when they request a call routed to that model, then LiteLLM routes to the next cheapest capable model with remaining budget.
- AC-009-4: Given LiteLLM is unavailable, when a Jido agent makes an LLM call, then the call fails with a descriptive error and the task is marked `blocked`. LiteLLM is always required; there is no direct API key fallback.
- AC-009-5: Given LiteLLM returns zero candidates for a `model="auto"` request (all models filtered out), when the router finishes evaluation, then the request fails with a descriptive error listing the filters that excluded all models, and the task is marked `blocked`.

---

### REQ-010: Jido MCP Client Integration

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: jido_mcp is beta (v0.1, GitHub-only); API surface may change]

Foreman shall use `jido_mcp` to allow agents to consume external MCP services as Jido actions.

- AC-010-1: Given `jido_mcp` is configured with an MCP server endpoint, when the agent calls a tool that maps to an MCP tool, then `jido_mcp` forwards the call to the MCP server and returns the result.
- AC-010-2: Given an MCP server is registered at runtime, when the agent lists available tools, then MCP tools from that server appear in the agent's toolset.
- AC-010-3: Given an MCP call fails, when the error is recoverable, then `jido_mcp` retries according to its configured policy; when it is not recoverable, then the agent receives an error directive.
- AC-010-4: Given `jido_mcp` receives a malformed response from an MCP server, when the response cannot be parsed or validated against the expected envelope, then the tool call returns an error result with bounded diagnostics (endpoint ID, tool ID, correlation ID, parse/schema error, response size, response hash). Raw body preserved only under an explicit secure debug policy.
- AC-010-5: Given `jido_mcp` is integrated into Foreman, when it is declared as a dependency, then it is forked under Sunstone-Partners and pinned to a specific git revision, consistent with AC-018-2.

---
### REQ-011: Jido Live Dashboard Integration

**Priority:** Should
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: jido_live_dashboard is beta; Phoenix dependency required]

Foreman should integrate `jido_live_dashboard` to expose real-time agent state in Phoenix LiveDashboard.

- AC-011-1: Given `jido_live_dashboard` is mounted in Foreman's Phoenix endpoint, when an operator opens the dashboard, then they see all active Jido agents, their current state, signal history, and directive queue.
- AC-011-2: Given an agent is running, when the dashboard is refreshed, then it shows current action, elapsed time, and recent signal activity within 1 second of the actual state change.
- AC-011-3: Given the Phoenix app is running without the LiveDashboard license, when an operator accesses the dashboard URL, then the existing Foreman auth guards apply and unauthorized access is rejected.

---

### REQ-012: Jido OpenTelemetry Integration

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: jido_otel tracer bridge must export spans to Langfuse-compatible OTLP endpoint]

Foreman shall use `jido_otel` to emit OpenTelemetry traces for every agent action and LLM call, exporting to Langfuse's OTLP-compatible ingestion endpoint.

- AC-012-1: Given `jido_otel` is configured with a Langfuse-compatible OTLP endpoint, when an agent calls `cmd/2`, then a span is emitted with action name, parameters, and duration.
- AC-012-2: Given an LLM call is made via `req_llm`, when the call completes, then an OTLP span is emitted with model, token counts, cost, and routing reason.
- AC-012-3: Given a signal is published on the bus, when the signal is dispatched, then an OTLP span is emitted with signal type, topic, and delivery status.

---

### REQ-013: Workflow Dispatch — `create`

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: exact ensemble skill names must be verified against live ensemble codebase]

Foreman shall dispatch the `create` workflow as a sequential chain of five Ensemble skills, each called with `--foreman` and an idempotency key.

- AC-013-1: Given a task of type `create` is approved, when Foreman starts it, then it dispatches `ensemble:create-prd` with `--foreman` and idempotency key `create-prd-{taskId}-1`.
- AC-013-2: Given `ensemble:create-prd` completes successfully, when its invocation record is `completed`, then Foreman dispatches `ensemble:refine-prd` with key `create-prd-{taskId}-2`.
- AC-013-3: Given `ensemble:refine-prd` completes, then `ensemble:create-trd` (key `create-prd-{taskId}-3`), then `ensemble:refine-trd` (key `create-prd-{taskId}-4`), then `ensemble:implement-trd` (key `create-prd-{taskId}-5`) — in sequence.
- AC-013-4: Given any step in the sequence fails, when the failure is terminal, then the task is marked `failed` and subsequent steps are not dispatched.
- AC-013-5: Given any step in the sequence blocks, when the block is due to a retryable condition, then the task is marked `blocked` and the step is retried when the condition clears.

---

### REQ-014: Workflow Dispatch — `implement`

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: exact ensemble skill name must be verified against live ensemble codebase]

Foreman shall dispatch the `implement` workflow by calling `ensemble-full-implement-trd` with `--foreman` and an idempotency key.

- AC-014-1: Given a task of type `implement` is approved, when Foreman starts it, then it dispatches `ensemble-full-implement-trd` with `--foreman` and idempotency key `implement-{taskId}-1`.
- AC-014-2: Given `ensemble-full-implement-trd` completes with a terminal status, when its invocation record is `completed`, then Foreman updates the task status accordingly.
- AC-014-3: Given `ensemble-full-implement-trd` fails with a terminal error, then the task is marked `failed`.

---

### REQ-015: Workflow Dispatch — `fix`

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: exact ensemble command name must be verified against live ensemble codebase]

Foreman shall dispatch the `fix` workflow by calling `ensemble:fix-issue` with `--foreman` and an idempotency key.

- AC-015-1: Given a task of type `fix` is approved, when Foreman starts it, then it dispatches `ensemble:fix-issue` with `--foreman` and idempotency key `fix-{taskId}-1`.
- AC-015-2: Given `ensemble:fix-issue` completes with a terminal status, when its invocation record is `completed`, then Foreman updates the task status accordingly.
- AC-015-3: Given `ensemble:fix-issue` fails with a terminal error, then the task is marked `failed`.

---

### REQ-016: Merge Gate — Human Review Required

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: gate bypass prevention]

Foreman shall require human approval before any branch is merged. Ensemble creates PRs; Foreman holds the merge gate. Agents shall not be able to trigger merge automatically.

- AC-016-1: Given a workflow reaches the merge phase, when Ensemble reports a PR is created, then Foreman pauses and requires an explicit human approval signal published to `foreman/commands`.
- AC-016-2: Given a merge approval is received, when the approver is verified as an authorized operator with a specific GitHub user identity matching the authorized identity, then the merge is executed.
- AC-016-3: Given an agent attempts to call a merge tool directly, then the tool refuses the call and logs a security event.

---

### REQ-017: Resumable Task Execution with Idempotent Invocation

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: crash window between Ensemble completion and Foreman persistence]

Foreman shall checkpoint agent state at each step boundary and use idempotency key reconciliation to prevent duplicate side effects on crash recovery.

- AC-017-1: Given a step completes, when its invocation record is written as `completed`, then Foreman persists the idempotency key and step result before dispatching the next step.
- AC-017-2: Given Foreman restarts with an incomplete task, when recovery is triggered, then Foreman queries each step's idempotency key to determine if it is `completed`, `started`, or `ambiguous` before re-dispatching.
- AC-017-3: Given a step's invocation record is `started` with an expired heartbeat lease, when Foreman detects the expiry, then the record is transitioned to `ambiguous` and Foreman reconciles before re-dispatching.
- AC-017-4: Given a task resumes from an ambiguous state, when Foreman reconciles, then it checks whether side effects (PR, documents) were committed before retrying, and skips re-execution if they were.
- AC-017-5: Given an agent crashes, when recovery is triggered, then the agent automatically restarts from its last checkpoint with an exponential backoff loop. After 5 consecutive restart failures, the task is marked `blocked` and an operator error is thrown. Recovery must achieve ≤30 seconds to resumption (NFR-03).

---

### REQ-018: Jido Repository Mirroring

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: upstream synchronization and fork maintenance]

Foreman shall fork and mirror all required Jido repositories to guarantee availability and enable local modifications.

- AC-018-1: Given a Jido package is identified as required, when it is first integrated, then Foreman forks the repository under the Sunstone-Partners GitHub organization and pins it to a specific git revision.
- AC-018-2: Given a fork is maintained, when a dependency is declared in `mix.exs`, then it pins to a specific git revision, not a floating version.
- AC-018-3: Given an upstream Jido package releases a new version, when Foreman evaluates the upgrade, then it immediately runs the existing action and signal test suite; Foreman adopts the update immediately after the suite passes, and does not adopt it if the suite fails.

---

### REQ-019: Action Development Speed Target

**Priority:** Must
**Complexity:** Low
**Type:** Non-Functional
**Risk:** [RISK: baseline is user-provided; representative action must be defined in TRD]

Foreman shall enable a new action to be authored, tested, and deployed in ≤4 hours (10× improvement over the user-provided 4-day baseline).

- AC-019-1: Given a developer follows the action authoring guide, when they implement a new `Jido.Action` module with tests, then the action is deployed via a process restart. All existing tests must pass before the restart completes the deployment.
- AC-019-2: Given a new action is deployed, when it is exercised by an agent, then the action's inputs, outputs, and duration are visible in `jido_live_dashboard` and traced via `jido_otel`.
- AC-019-3: Given the 4-hour speed target, when the TRD is written, then it defines one representative action with mocked/sandbox external services and a completion checklist (typed inputs/outputs, side effect/integration, registration, unit + integration tests, documentation, deployment).
- AC-019-4: Given a Jido package upgrade is proposed, when the upgrade is evaluated, then compatibility tests run against the representative action to detect regressions in the development speed target.

---

### REQ-020: LiteLLM Routing Auditability

**Priority:** Must
**Complexity:** Medium
**Type:** Non-Functional
**Risk:** [RISK: routing table accuracy and model capability declarations]

LiteLLM routing decisions shall be deterministic and auditable: every `model="auto"` call must produce a Langfuse trace entry showing which models were evaluated and why the winning model was selected.

- AC-020-1: Given a `model="auto"` request completes, when the Langfuse trace is inspected, then `metadata.routed_to` contains the selected model and routing reason.
- AC-020-2: Given a model's capability or price changes, when the routing config is updated, then existing routing tests are re-run to verify decisions are unaffected.

---

### REQ-021: Security — Agent Isolation

**Priority:** Must
**Complexity:** High
**Type:** Non-Functional
**Risk:** [RISK: privilege escalation and worktree contamination]

Agents shall run in isolated environments with no ability to escalate privileges or access resources outside their assigned worktree.

- AC-021-1: Given an agent is running via `jido_shell`, when it attempts to access a path outside its worktree, then the access is denied by `jido_vfs` sandbox policy and a security event is logged.
- AC-021-2: Given an agent attempts to modify Foreman's internal state directly, when it bypasses the signal interface, then the attempt is denied and a security event is logged.
- AC-021-3: Given an agent calls an MCP tool, when the tool requests a capability outside its allowlist, then `jido_mcp` rejects the call and logs a security event.
- AC-021-4: Given `jido_workspace` is used for worktree isolation, when the validation spike completes, then sandbox enforcement (network deny-by-default, command allowlisting) is confirmed as active for the host-path worktree.

---

### REQ-022: Legacy Backend Removal

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: inadvertent feature loss during removal]

Foreman shall remove all custom agent/orchestration code built prior to the Jido migration.

- AC-022-1: Given the migration is complete, when the codebase is scanned for custom agent implementations, then no files remain that implement agent lifecycle, action dispatch, or tool registration outside of Jido packages.
- AC-022-2: Given the migration is complete, when `create`, `implement`, and `fix` workflows run, then they produce equivalent observable outcomes (PR created, task status updated, operator notified) without relying on any pre-migration code.
- AC-022-3: Given removed code is archived, when a developer needs historical reference, then the code is available in a dedicated archived branch.

---

### REQ-023: Signal Delivery Latency

**Priority:** Should
**Complexity:** Low
**Type:** Non-Functional
**Risk:** [RISK: monitoring and alerting]

Signals between agents, and from agents to operators, shall be delivered within 1 second at p95 under normal load.

- AC-023-1: Given an agent publishes a signal, when the signal is consumed by a subscribed agent, then end-to-end latency is under 1 second at p95.
- AC-023-2: Given an operator question signal is emitted, when the Foreman inbox API receives it, then the signal appears within 1 second at p95.

---

### REQ-024: Characterization Test Harness

**Priority:** Must
**Complexity:** Medium
**Type:** Functional
**Risk:** [RISK: test harness must verify dispatch contracts and failure propagation, not implementation internals]

Foreman shall have a characterization test harness that verifies workflow dispatch correctness, failure propagation, and resume behavior — not implementation details.

- AC-024-1: Given the characterization harness exercises the `create` workflow, when it runs with the same inputs as the original implementation, then it verifies: (a) correct skill dispatched in correct order, (b) output routed correctly to Foreman, (c) PR created by Ensemble (if applicable), (d) Foreman's merge gate holds until human approval.
- AC-024-2: Given the characterization harness exercises the `implement` workflow, when it runs, then it verifies correct dispatch of `ensemble-full-implement-trd` with correct inputs and output routing.
- AC-024-3: Given the characterization harness exercises the `fix` workflow, when it runs, then it verifies correct dispatch of `ensemble:fix-issue` with correct inputs and output routing.
- AC-024-4: Given a step in the `create` sequence fails with a terminal error, when the harness verifies recovery, then the task is marked `failed` and no subsequent steps are dispatched.
- AC-024-5: Given Foreman crashes mid-sequence and restarts, when recovery is triggered, then the harness verifies Foreman resumes from the next incomplete step without re-executing completed steps (idempotency key check) and without creating duplicate side effects.

---

### REQ-025: Hot-Loadable Workflow Format

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: format must be defined; must not require Foreman rebuild to add a new workflow]

Foreman shall allow operators to define new workflows in a declarative format that does not require rebuilding or redeploying Foreman.

- AC-025-1: Given an operator writes a new workflow definition in the supported format, when the definition is placed in the configured workflow directory, then Foreman loads it without a restart.
- AC-025-2: Given a workflow definition is loaded, when it is parsed, then Foreman validates that it dispatches a known Ensemble skill or a defined sequence of skills with valid idempotency keys.
- AC-025-3: Given an operator defines an invalid workflow (unknown skill, missing required field), when Foreman attempts to load it, then it rejects the definition with a descriptive error and does not crash. The supported formats are YAML and Elixir DSL.

---

### REQ-026: Ensemble `--foreman` Mode Idempotency Enhancement

**Priority:** Must
**Complexity:** High
**Type:** Functional
**Risk:** [RISK: requires modification to Ensemble skills; modifications live in worktree at ~/Development/Sunstone/ensemble]

Each Ensemble skill must be enhanced to support idempotent invocation when called with `--foreman`.

- AC-026-1: Given an Ensemble skill is called with `--foreman` and an idempotency key, when the skill starts, then it writes a durable invocation record as `started` with a heartbeat lease before reporting side effects.
- AC-026-2: Given an Ensemble skill receives the same idempotency key it has already processed, when it checks the invocation record, then it returns the cached result without re-executing (idempotent replay).
- AC-026-3: Given an Ensemble skill completes, when it writes its result, then the invocation record is transitioned to `completed` and the lease is released before side effects are reported as complete.
- AC-026-4: Given Foreman times out waiting for an Ensemble skill response, when Foreman re-dispatches with the same key, then Ensemble returns the cached result if `completed`, or reconciles if `ambiguous`, without duplicate side effects.
- AC-026-5: Given the implementation requires modifications to Ensemble, when modifications are needed, then they are developed in a worktree created via worktrunk at `~/Development/Sunstone/ensemble`.

---

## 7. Non-Functional Requirements Summary

| ID | Category | Requirement | Target |
|----|----------|-------------|--------|
| NFR-01 | Performance | Action development time | ≤4 hours end-to-end (10× vs 4-day user-provided baseline) |
| NFR-02 | Performance | Signal delivery latency | p95 < 1 second |
| NFR-03 | Performance | Agent crash recovery time | ≤30 seconds to resumption |
| NFR-04 | Reliability | Checkpoint durability | Agent state survives Foreman restart via jido_ecto |
| NFR-05 | Reliability | No auto-merge | Human approval always required |
| NFR-06 | Reliability | Idempotent Ensemble dispatch | No duplicate side effects from crash/retry |
| NFR-07 | Observability | LLM trace coverage | 100% of LLM calls traced in Langfuse |
| NFR-08 | Observability | Agent state visibility | jido_live_dashboard shows full agent state |
| NFR-09 | Observability | Signal trace coverage | 100% of signals traced via jido_otel |
| NFR-10 | Security | Agent isolation | No privilege escalation; worktree-scoped only |
| NFR-11 | Security | Merge gate integrity | Agents cannot bypass human review |
| NFR-12 | Maintainability | Repo mirroring | All required Jido packages forked and pinned |
| NFR-13 | Compatibility | LiteLLM integration | `model="auto"` routes by capability |

---

## 8. Dependency Map

| REQ | Depends On | Blocked By | Notes |
|-----|-----------|-----------|-------|
| REQ-001 | — | — | Foundation; Jido agents own agent/checkpoint state via jido_ecto; authoritative Task/Run/Inbox domain events remain in Foreman's event store |
| REQ-002 | REQ-001 | — | Actions depend on running Jido runtime |
| REQ-003 | REQ-001 | — | jido_harness Pi adapter |
| REQ-004 | REQ-001 | — | Signal bus requires Jido runtime |
| REQ-005 | REQ-001, REQ-004 | — | Operator signals use Signal infrastructure |
| REQ-006 | REQ-001, REQ-004 | — | Foreman signal integration |
| REQ-007 | REQ-001 | — | jido_shell + jido_vfs; jido_workspace is spike |
| REQ-008 | REQ-001, REQ-009 | — | AI strategies need LLM client + LiteLLM |
| REQ-009 | — | — | External stack; no internal dependencies |
| REQ-010 | REQ-001, REQ-002 | — | MCP client wraps Jido actions |
| REQ-011 | REQ-001 | — | Dashboard requires Phoenix endpoint |
| REQ-012 | REQ-001, REQ-009 | — | OTEL traces LLM calls and signals |
| REQ-013 | REQ-001, REQ-026 | — | `create` dispatch depends on idempotency |
| REQ-014 | REQ-001, REQ-026 | — | `implement` dispatch depends on idempotency |
| REQ-015 | REQ-001, REQ-026 | — | `fix` dispatch depends on idempotency |
| REQ-016 | REQ-001, REQ-006 | — | Merge gate requires Foreman signal integration |
| REQ-017 | REQ-001 | REQ-013, REQ-014, REQ-015 | Checkpointing built after workflows defined |
| REQ-018 | — | — | Independent; run first |
| REQ-019 | REQ-002 | REQ-018 | Speed target validated after actions defined |
| REQ-020 | REQ-009 | — | LiteLLM tracing |
| REQ-021 | REQ-001 | — | Security isolation built on Jido runtime |
| REQ-022 | REQ-013, REQ-014, REQ-015 | — | Removal confirmed after workflows validated |
| REQ-023 | REQ-004 | — | Signal latency; no other dependencies |
| REQ-024 | REQ-013, REQ-014, REQ-015 | — | Characterization harness |
| REQ-025 | REQ-001 | — | Hot-loadable workflow format |
| REQ-026 | — | — | Independent; must be ready before dispatch workflows |

---

## 9. Technical Dependencies

### 9.1 Jido Packages — Stability and Risk Profile

| Package | Version | Stability | Source | Risk |
|---------|---------|-----------|--------|------|
| `jido` | ~> 2.0 | Stable | Hex | None |
| `jido_action` | ~> 2.2 | Stable | Hex | None |
| `jido_signal` | ~> 2.0 | Stable | Hex | None |
| `jido_shell` | ~> 1.0 | Stable | Hex | None |
| `jido_vfs` | ~> 1.0 | Stable | Hex | None |
| `jido_ai` | ~> 1.0 | Stable | Hex | None |
| `jido_harness` | ~> 1.0 | Stable | Hex | None |
| `jido_ecto` | ~> 1.0 | Stable | Hex | None |
| `req_llm` | ~> 1.0 | Stable | Hex | None |
| `jido_otel` | ~> 1.0 | Stable | Hex | None |
| `jido_mcp` | ~> 0.1 | **Beta** | **GitHub only** | [RISK: API may break on minor releases; requires fork + pin] |
| `jido_live_dashboard` | beta | **Beta** | **GitHub only** | [RISK: Phoenix dependency required; beta API] |
| `jido_workspace` | ~> 0.1.0 | **Beta** | **GitHub only** | [RISK: in-memory VFS by default; snapshot semantics evolving; validate worktree binding and sandbox enforcement before production use] |

### 9.2 Beta Package Mitigation Strategy

For each beta package, the mitigation is the same:

1. Fork to `Sunstone-Partners` GitHub at integration time
2. Pin to specific git revision in `mix.exs`
3. Run full action/signal test suite after any upstream update
4. Track upstream releases and evaluate updates immediately on release; run full action/signal test suite; adopt immediately after suite passes, do not adopt if suite fails

### 9.3 External Services

| Service | Purpose | Integration Point |
|---------|---------|-------------------|
| `LiteLLM` | Model gateway | Existing local stack at port 4000 |
| `Langfuse` | LLM observability | Existing local stack at port 3000 |
| `PostgreSQL` | Jido durable state via `jido_ecto`; Foreman task store | Shared Postgres instance |
| `GitHub API` | PR operations | Via `jido_shell` or MCP tools |
| External MCP servers | Tools/resources | Via `jido_mcp` client pool |
| `Ensemble` | PRD/TRD creation, refinement, implementation skills | HTTP dispatch from Foreman agent |

### 9.4 Ensemble Integration

Ensemble lives at `~/Development/Sunstone/ensemble`. Modifications to Ensemble (for `--foreman` idempotency enhancements) are made in a worktree created via worktrunk.

| Ensemble Skill | Role | Foreman Dispatch Key |
|---|---|---|
| `ensemble:create-prd` | Create product requirements document | `create-prd-{taskId}-1` |
| `ensemble:refine-prd` | Refine product requirements document | `create-prd-{taskId}-2` |
| `ensemble:create-trd` | Create technical requirements document | `create-prd-{taskId}-3` |
| `ensemble:refine-trd` | Refine technical requirements document | `create-prd-{taskId}-4` |
| `ensemble:implement-trd` | Implement a TRD | `create-prd-{taskId}-5` |
| `ensemble-full-implement-trd` | Implement a TRD using Beads | `implement-{taskId}-1` |
| `ensemble:fix-issue` | Fix an issue | `fix-{taskId}-1` |

---

## 10. Ambiguity Markers Summary — Resolved

All ambiguity markers have been resolved through the refine-prd interview.

| # | REQ | Question | Resolution |
|---|-----|----------|------------|
| 1 | REQ-002 | Test coverage threshold for new actions? | 85% code coverage (AC-002-4) |
| 2 | REQ-004 | Missing subscriber policy — silent, warn, or error? | Configurable (silent/warn/error); default warn (AC-004-3) |
| 3 | REQ-005 | Operator response timeout — default and configurability? | Configurable per workflow in workflow definition (AC-005-3) |
| 4 | REQ-007 | Shell session survival on agent restart? | Tied to agent lifecycle; agent restart creates new session (AC-007-4) |
| 5 | REQ-009 | LiteLLM fallback when unavailable? | LiteLLM always required; no direct API key fallback (AC-009-4) |
| 6 | REQ-010 | `jido_mcp` fork/pin decision? | Fork under Sunstone-Partners; pinned to specific git revision (AC-010-5) |
| 7 | REQ-025 | Hot-loadable workflow format? | YAML and Elixir DSL (AC-025-3) |

---

## 11. Implementation Readiness Gate

*Scored after Phase 4 refine-prd interview. All ambiguity markers resolved.*

| Dimension | Score (1–5) | Rationale |
|:--|--|--|
| Completeness | 5 | 26 requirements (001–026); all Must/Should covered; AC-017-5 adds NFR-03 coverage; hot-loadable format formally specified |
| Testability | 5 | Every Must/Should has Given/When/Then ACs; characterization harness (REQ-024); benchmark (REQ-019); 85% coverage threshold (AC-002-4); zero-candidates AC (AC-009-5) |
| Clarity | 5 | Exact dispatch contracts named; workflow format (YAML/Elixir DSL); event-source architecture clarified (Foreman owns Task/Run/Inbox events, jido_ecto is agent/checkpoint adapter only); all markers cleared |
| Feasibility | 5 | Beta packages mitigated by fork/pin strategy; jido_workspace validation spike defined; jido_harness scoped to new interface; jido_ecto correctly scoped to Jido agent/checkpoint state; Ensemble idempotency via worktrunk worktree |
| **Overall** | **5.0 / 5.0** | |

**Gate: PASS**

---

## 12. Next Steps

1. ~~Run `/ensemble:refine-prd` to resolve ambiguity markers~~ — all 7 resolved
2. Review and approve this PRD
3. Proceed to `/ensemble:create-trd docs/PRD/PRD-2026-4212be7e-jido-migration.md`
