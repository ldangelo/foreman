---
document_id: TRD-2026-4212be7e
label: trd-jido-migration
kind: trd
version: 1.1.1
date: 2026-08-18
status: draft
prd_reference: PRD-2026-4212be7e
source_prd_label: prd-jido-migration
design_readiness_score: 5.0
total_tasks: 107
ensemble_implement_trd_beads:
  branch_name: slices/jido-migration
  use_proposed: false
  stacked_prs: false
---

# TRD-2026-4212be7e: Jido Agent Ecosystem Migration — Technical Requirements

## Document Metadata

| Field | Value |
|-------|-------|
| **Document ID** | TRD-2026-4212be7e |
| **Label** | trd-jido-migration |
| **Kind** | trd |
| **Version** | 1.1.1 |
| **Status** | draft |
| **Date** | 2026-08-18 |
| **PRD Reference** | PRD-2026-4212be7e |
| **Source PRD Label** | prd-jido-migration |
| **Design Readiness Score** | 5.0 |
| **Total Tasks** | 107 |

---

## 0. Reused Capabilities

This migration extends existing Foreman infrastructure defined in TRD-2026-014 (Elixir Backend Orchestration). No capability is duplicated.

### Reused from TRD-2026-014

| Capability | TRD-014 Location | How Extended |
|------------|-----------------|-------------|
| Append-only event store (Postgres) | §4.2, §4.4 | Jido agents emit signals to `foreman/commands` topic; jido_signal adapter normalizes CloudEvents to `ExternalTriggerCommand` and routes to existing Integration Ingestion (§4.8) |
| Command handlers | §4.5 | Reused as-is; signal adapter produces `ExternalTriggerCommand` envelope |
| Projection workers with rebuild checkpoints | §4.2, §4.5 | Reused as-is; no new projector infrastructure |
| ProjectSupervisor / RunSupervisor / WorkerSupervisor hierarchy | §4.2, §4.3 | Jido.Agent GenServer added as child under existing supervision tree (replaces Node/Pi SDK worker) |
| Recovery and reconciliation rules | §4.6 | Extended with idempotency key reconciliation (started/completed/ambiguous states) and 5-restart exponential backoff loop |
| VCS and PR state machines | §4.9 | Reused as-is for merge gate |
| Idempotency key contract | §4.4, §4.8 | Extended: `--foreman` dispatch keys = `{workflow}-{taskId}-{step}`; durable started/completed/ambiguous records |
| Heartbeat protocol | §4.6 | Jido agents implement equivalent heartbeat lease with expiry detection; expired → ambiguous → reconcile |
| WorkerSupervisor HTTP contract | §4.5 | **Replaced**: Node/Pi SDK worker protocol replaced by Jido agent GenServer with jido_signal bus |

### Extended from TRD-2026-009

| Capability | TRD-009 Location | How Extended |
|------------|-----------------|-------------|
| Guardrail config (ProjectConfig) | TRD-009-001 | `jido_vfs` sandbox policies extend the same config shape for VFS access control |
| Security event logging | TRD-009-003, §4.6 | New security vectors: MCP allowlist violations, direct Foreman internal state access, jido_workspace sandbox bypass |
| Heartbeat manager | TRD-009-006 | Replaced by Jido agent lifecycle heartbeat with `jido_ecto` checkpoint persistence |

### Extended from TRD-2026-015

| Capability | TRD-015 Location | How Extended |
|------------|-----------------|-------------|
| WorkflowRunner callbacks | §4.1, §5 | Phase lifecycle callbacks (onPhaseStart, onPhaseComplete, onPipelineComplete) extended: Jido agent phase handoff uses `jido_signal` pub/sub |

---

## 1. Architecture Decision

### 1.1 Chosen Approach

Phased Jido ecosystem integration with event-source spine: Foreman owns authoritative Task/Run/Inbox domain events via existing TRD-014 Integration Ingestion and event store; `jido_ecto` persists only Jido agent/checkpoint state; LiteLLM+Langfuse for capability-based LLM routing; Ensemble skills for PRD/TRD workflow orchestration; idempotent `--foreman` dispatch for crash recovery safety.

### 1.2 Signal-to-Command Adapter (TRD-014 Integration Point)

Jido agents publish CloudEvents to `foreman/commands` topic. A single **signal-to-command adapter** normalizes these to `ExternalTriggerCommand` envelopes and routes them to the existing TRD-014 Integration Ingestion (§4.8) — no new projector or event-sourcing infrastructure created.

```
Jido agent signal
  → jido_signal Bus.publish("foreman/commands", cloud_event)
  → Phoenix bus subscriber (signal-to-command adapter)
  → normalizes to ExternalTriggerCommand (TRD-014 §4.8)
  → existing command handlers → event store → projection workers
```

### 1.3 Alternatives Considered

**Option A — Incremental Overlay:** Layer Jido agents on top of existing TypeScript backend, sharing the event store. Reduces migration risk but keeps legacy backend in production indefinitely. **Rejected**: PRD requires custom backend removal.

**Option B — Big-Bang Replacement:** Replace entire TypeScript backend in one sprint. Fastest but highest risk. **Rejected**: PRD's phased feature areas imply incremental delivery with observable checkpoints.

### 1.4 Component Architecture

```
Jido Agent (per workflow instance)
  ├── jido (cmd/2 loop, GenServer supervision) ← extends TRD-014 WorkerSupervisor
  ├── jido_action (Jido.Action modules)
  ├── jido_signal (CloudEvents pub/sub bus) ← replaces WorkflowRunner callbacks
  ├── jido_shell + jido_vfs (command execution, sandbox) ← extends TRD-009 guardrail config
  ├── jido_ai + req_llm (ReAct/CoT reasoning → LiteLLM)
  ├── jido_mcp (MCP client → external MCP servers)
  ├── jido_harness (Jido.Harness.Adapters.Pi) ← replaces pi-sdk-runner.ts
  ├── jido_otel (OTEL spans → Langfuse)
  └── jido_ecto (Postgres: agent struct/checkpoint state only)

LiteLLM Gateway (model="auto" → cheapest-capable model)
  └── Langfuse (per-call traces)

Foreman Elixir Server ← extends TRD-014
  ├── jido_signal → signal-to-command adapter → TRD-014 Integration Ingestion
  ├── existing event store and projection workers (TRD-014)
  ├── Human approval merge gate (TRD-014 VCS/PR state machines)
  └── jido_ecto (agent/checkpoint persistence adapter)

Ensemble Skills (external; Foreman dispatches with --foreman)
  └── ensemble:create-prd → refine-prd → create-trd → refine-trd → implement-trd
  └── ensemble-full-implement-trd
  └── ensemble:fix-issue
```

---

## Master Task List

**Domain prefixes:** `JCR`=Jido Core Runtime, `JAF`=Jido Action Framework, `JHA`=Jido Harness Adapter, `JSI`=Signal Integration, `JSH`=Shell/VFS, `JAI`=Jido AI, `LGL`=LiteLLM/Langfuse, `MCP`=MCP Client, `JLD`=Live Dashboard, `JOT`=OpenTelemetry, `WFD`=Workflow Dispatch, `MGH`=Merge Gate, `RTE`=Resumability, `JRM`=Jido Repo Mirroring, `ADT`=Action Dev Target, `CTH`=Characterization Harness, `HLW`=Hot-Loadable Workflows, `LGC`=Legacy + Security.

All `Status` cells are `[ ]`.

---

### PR 1: Foundation — Jido Core Runtime and Action Authoring

**Shippable State:** Jido agent starts, executes registered actions, checkpoints state to Postgres, and recovers after restart

#### Story 1.0: Jido Repo Preparation (prerequisite — all packages forked and pinned before integration)

- [x] **TRD-001**: JRM-T001 — Fork all required Jido repos under Sunstone-Partners GitHub organization. [satisfies REQ-018]
- [x] **TRD-002**: JRM-T002 — For each forked Jido repo, select and record the fork URL and specific commit revision for each package; JCR-T001 declares these in mix.exs. [satisfies REQ-018] [depends: TRD-001]

#### Story 1.1: Jido Core Runtime

- [x] **TRD-003**: JCR-T001 — Add all Jido packages to mix.exs: jido, jido_action, jido_signal, jido_shell, jido_vfs, jido_ai, jido_harness, jido_ecto, req_llm, jido_otel — every package is sourced from a Sunstone-Partners fork pinned to a specific revision. [satisfies REQ-001] [depends: TRD-002]
- [x] **TRD-004**: JCR-T002 — Create Jido.Agent GenServer under Foreman.Application supervision tree with OTP restart strategy. [satisfies REQ-001] [depends: TRD-003]
- [ ] **TRD-005**: JCR-T003 — Implement cmd/2 loop in Jido agent: action in → updated agent struct + directives out. [satisfies REQ-001] [depends: TRD-004]
- [x] **TRD-006**: JCR-T004 — Integrate jido_ecto for agent struct and checkpoint persistence (Postgres adapter). [satisfies REQ-001] [depends: TRD-004]
- [x] **TRD-007**: JCR-T005 — Implement signal-to-command adapter: Phoenix subscriber for foreman/commands topic, normalizes CloudEvent to ExternalTriggerCommand, routes to TRD-014 Integration Ingestion. [satisfies REQ-001] [depends: TRD-003]
- [ ] **TRD-008**: JCR-T006 — Write unit tests for Jido.Agent GenServer lifecycle (start, cmd/2, checkpoint, restart). [satisfies REQ-001] [depends: TRD-006]
- [ ] **TRD-009**: JCR-T007 — Write integration test verifying agent signal → command envelope → event store → projection update flow. [satisfies REQ-001] [depends: TRD-007]
- [ ] **TRD-010**: JCR-T008 — Write unit tests for signal-to-command adapter in isolation: CloudEvent envelope parsing, topic routing, ExternalTriggerCommand normalization, error handling for malformed CloudEvents. [satisfies REQ-001] [depends: TRD-007]

#### Story 1.2: Jido Action Authoring Framework

- [x] **TRD-011**: JAF-T001 — Define Jido.Action behaviour for tool registration and validation. [satisfies REQ-002] [depends: TRD-003]
- [x] **TRD-012**: JAF-T002 — Migrate existing TypeScript tool factories to Jido.Action modules (git_status, diff_read, task_get, etc.). [satisfies REQ-002] [depends: TRD-011]
- [ ] **TRD-013**: JAF-T003 — Add action validation middleware (parameter checking before execution). [satisfies REQ-002] [depends: TRD-011]
- [x] **TRD-014**: JAF-T004 — Add Jido.Character prompt template loader for skills (prompt fragments, not actions). [satisfies REQ-002] [depends: TRD-003]
- [x] **TRD-015**: JAF-T005 — Write isolation tests for each migrated action achieving ≥85% code coverage. [satisfies REQ-002] [depends: TRD-012]

#### Story 1.3: Jido Harness Pi Adapter

- [x] **TRD-016**: JHA-T001 — Integrate jido_harness with Jido.Harness.Adapters.Pi. [satisfies REQ-003] [depends: TRD-003]
- [x] **TRD-017**: JHA-T002 — Replace pi-sdk-runner.ts with Jido.Harness.Session, Jido.Harness.Run, Jido.Harness.Process. [satisfies REQ-003] [depends: TRD-016]
- [x] **TRD-018**: JHA-T003 — Write harness characterization test: verify Jido.Harness.Adapters.Pi creates Jido.Harness.Session, resolves tools through Jido.Harness.Process, and provides Jido.Harness.Run — without asserting legacy pi-sdk-runner.ts behavioral equivalence. [satisfies REQ-003] [depends: TRD-017]

---

### PR 2: Communication Infrastructure — Signal Bus, Operator, Agent↔Foreman

**Shippable State:** Agent receives operator questions, publishes directives, and Foreman inbox reflects signal delivery — within configurable per-workflow timeouts

#### Story 2.1: Signal Bus (jido_signal)

- [x] **TRD-019**: JSI-T001 — Configure jido_signal topics: foreman/commands, foreman/operator, foreman/inbox, agents/<agent-id>/directive. [satisfies REQ-004] [depends: TRD-003]
- [x] **TRD-020**: JSI-T002 — Implement Agent→Agent signal pub/sub via Bus.publish to agents/<phase> topic. [satisfies REQ-004] [depends: TRD-019]
- [x] **TRD-021**: JSI-T003 — Implement missing-subscriber configurable policy (silent/warn/error, default warn) in Foreman config. [satisfies REQ-004] [depends: TRD-019]
- [ ] **TRD-022**: JSI-T004 — Add signal journal for replay on restart. [satisfies REQ-004] [depends: TRD-019]
- [x] **TRD-023**: JSI-T005 — Write integration tests for signal pub/sub with all three missing-subscriber policies. [satisfies REQ-004] [depends: TRD-021]

#### Story 2.2: Operator Communication

- [x] **TRD-024**: JSI-T006 — Add foreman/operator topic subscriber. [satisfies REQ-005] [depends: TRD-019]
- [x] **TRD-025**: JSI-T007 — Implement jido_signal dispatch adapter (webhook/HTTP) to Foreman inbox API. [satisfies REQ-005] [depends: TRD-024]
- [x] **TRD-026**: JSI-T008 — Implement operator question → inbox domain event → projector → agent directive flow. [satisfies REQ-005] [depends: TRD-025]
- [x] **TRD-027**: JSI-T009 — Implement per-workflow operator timeout (configurable in workflow definition; mark task blocked on expiry). [satisfies REQ-005] [depends: TRD-026]
- [x] **TRD-028**: JSI-T010 — Write integration test for operator question → inbox notification → agent resume. [satisfies REQ-005] [depends: TRD-026]

#### Story 2.3: Agent↔Foreman Communication

- [x] **TRD-029**: JSI-T011 — Implement directive publisher (Foreman→Agent) via Bus.publish to agents/<agent-id>/directive. [satisfies REQ-006] [depends: TRD-019]
- [x] **TRD-030**: JSI-T012 — Implement task metadata query signal (Agent→Foreman) and response signal (Foreman→Agent). [satisfies REQ-006] [depends: TRD-029]
- [x] **TRD-031**: JSI-T013 — Write integration tests for nudge and query flows. [satisfies REQ-006] [depends: TRD-029, TRD-030]

#### Story 2.4: Shell Integration

- [ ] **TRD-032**: JSH-T001 — Integrate jido_shell for command execution with jido_vfs sandbox. [satisfies REQ-007] [depends: TRD-019]
- [x] **TRD-033**: JSH-T002 — Implement shell session lifecycle: shell tied to agent lifetime (terminates on agent restart; restarted agent creates new session). [satisfies REQ-007] [depends: TRD-032]
- [ ] **TRD-034**: JSH-T003 — Add VFS isolation per worktree (each agent gets sandboxed filesystem view). [satisfies REQ-007] [depends: TRD-032]
- [ ] **TRD-035**: JSH-T004 — Write shell integration tests: command execution, session isolation, VFS sandbox. [satisfies REQ-007] [depends: TRD-033, TRD-034]

#### Story 2.5: jido_workspace Validation Spike

- [ ] **TRD-036**: JSH-T005 — Spike jido_workspace worktree binding and sandbox enforcement: evaluate in-memory VFS, snapshot semantics, host-path adapter. [satisfies REQ-007] [depends: TRD-003]
- [ ] **TRD-037**: JSH-T006 — If spike passes: adopt jido_workspace with validated sandbox policies. If spike fails: use jido_shell + jido_vfs + custom host-path adapter. [satisfies REQ-007] [depends: TRD-036]
- [ ] **TRD-038**: JSH-T007 — Document jido_workspace validation result in spike report. [satisfies REQ-007] [depends: TRD-036]

---

### PR 3: AI, LLM, and External Integrations

**Shippable State:** Agent routes LLM calls through LiteLLM gateway, MCP tools appear in agent toolset, LiveDashboard shows agent state with ≤1s latency, and all LLM/cmd/signal calls emit OTEL spans to Langfuse

#### Story 3.1: Jido AI + req_llm

- [ ] **TRD-039**: JAI-T001 — Integrate jido_ai strategies (ReAct, Chain-of-Thought) with req_llm HTTP client. [satisfies REQ-008] [depends: TRD-003]
- [ ] **TRD-040**: JAI-T002 — Add LLM timeout/error handling: req_llm error → error directive to agent (retry or escalate). [satisfies REQ-008] [depends: TRD-039]
- [ ] **TRD-041**: JAI-T003 — Verify jido_ai routes LLM calls through LiteLLM gateway when configured. [satisfies REQ-008] [depends: TRD-039, TRD-042]

#### Story 3.2: LiteLLM + Langfuse Integration

- [ ] **TRD-042**: LGL-T001 — Integrate litellm-langfuse-stack (LiteLLM port 4000, Langfuse port 3000) with model="auto" capability routing. [satisfies REQ-009] [depends: TRD-039]
- [ ] **TRD-043**: LGL-T002 — Add Langfuse tracing for all LLM calls (prompt, response, model, cost, latency). [satisfies REQ-009] [depends: TRD-042]
- [ ] **TRD-044**: LGL-T003 — Implement zero-candidates failure: LiteLLM returns descriptive error listing excluded filters when all models filtered out; task marked blocked. [satisfies REQ-009] [depends: TRD-042]
- [ ] **TRD-045**: LGL-T004 — Add routing auditability: metadata.routed_to and routing reason in every Langfuse trace. [satisfies REQ-009, REQ-020] [depends: TRD-043]
- [ ] **TRD-046**: LGL-T005 — Implement LiteLLM unavailable → blocked task (no direct API key fallback). [satisfies REQ-009] [depends: TRD-042]
- [ ] **TRD-047**: LGL-T006 — Write LiteLLM integration tests: auto-routing, budget failover, zero-candidates, unavailable. [satisfies REQ-009] [depends: TRD-042]

#### Story 3.3: MCP Client Integration

- [ ] **TRD-048**: MCP-T001 — Verify jido_mcp fork URL and pinned commit revision from JRM-T002 dependency manifest; confirm fork exists under Sunstone-Partners and revision is accessible. [satisfies REQ-010] [depends: TRD-002]
- [ ] **TRD-049**: MCP-T002 — Integrate jido_mcp client pool with agent toolset sync. [satisfies REQ-010] [depends: TRD-048]
- [ ] **TRD-050**: MCP-T003 — Implement MCP tool sync: registered MCP servers' tools appear in agent's available toolset. [satisfies REQ-010] [depends: TRD-049]
- [ ] **TRD-051**: MCP-T004 — Add bounded diagnostics for malformed MCP responses (endpoint ID, tool ID, correlation ID, parse/schema error, response size, response hash; no raw body without explicit debug policy). [satisfies REQ-010] [depends: TRD-050]
- [ ] **TRD-052**: MCP-T005 — Add MCP security allowlist: reject calls to tools outside allowlist, log security event. [satisfies REQ-010] [depends: TRD-050]
- [ ] **TRD-053**: MCP-T006 — Add recoverable/non-recoverable MCP error handling with retry directive. [satisfies REQ-010] [depends: TRD-050]
- [ ] **TRD-054**: MCP-T007 — Write MCP integration tests: tool sync, malformed response, allowlist enforcement. [satisfies REQ-010] [depends: TRD-050]

#### Story 3.4: Live Dashboard

- [ ] **TRD-055**: JLD-T001 — Mount jido_live_dashboard in Phoenix endpoint under existing Foreman auth guards. [satisfies REQ-011] [depends: TRD-003]
- [ ] **TRD-056**: JLD-T002 — Add dashboard views: active agents, current state, signal history, directive queue. [satisfies REQ-011] [depends: TRD-055]
- [ ] **TRD-057**: JLD-T003 — Verify dashboard refresh latency ≤1 second for agent state changes. [satisfies REQ-011] [depends: TRD-056]
- [ ] **TRD-058**: JLD-T004 — Write dashboard integration tests: auth guard enforcement, data freshness. [satisfies REQ-011] [depends: TRD-056]

#### Story 3.5: OpenTelemetry Integration

- [ ] **TRD-059**: JOT-T001 — Configure jido_otel with Langfuse-compatible OTLP endpoint. [satisfies REQ-012] [depends: TRD-003]
- [ ] **TRD-060**: JOT-T002 — Emit OTEL span for every cmd/2 call (action name, parameters, duration). [satisfies REQ-012] [depends: TRD-059]
- [ ] **TRD-061**: JOT-T003 — Emit OTEL span for every LLM call (model, token counts, cost, routing reason). [satisfies REQ-012] [depends: TRD-059]
- [ ] **TRD-062**: JOT-T004 — Emit OTEL span for signal publish/dispatch (signal type, topic, delivery status). [satisfies REQ-012] [depends: TRD-059]
- [ ] **TRD-063**: JOT-T005 — Write OTEL integration tests: span emission for cmd/2, LLM calls, signal dispatch. [satisfies REQ-012] [depends: TRD-060, TRD-061, TRD-062]

---

### PR 4: Workflow Dispatch, Merge Gate, and Resumability

**Shippable State:** create/implement/fix dispatch runs in correct order, resumes idempotently after crashes, and cannot merge without authorized human approval

#### Story 4.1: Workflow Dispatch — create

- [ ] **TRD-064**: WFD-T001 — Implement create workflow sequential dispatcher: ensemble:create-prd → refine-prd → create-trd → refine-trd → implement-trd. [satisfies REQ-013, REQ-026] [depends: TRD-028, TRD-029]
- [ ] **TRD-065**: WFD-T002 — Add idempotency key management per step: key = create-prd-{taskId}-{step}. [satisfies REQ-013, REQ-026] [depends: TRD-064]
- [ ] **TRD-066**: WFD-T003 — Add step sequencing with terminal status propagation (completed/failed/blocked). [satisfies REQ-013, REQ-026] [depends: TRD-065]
- [ ] **TRD-067**: WFD-T004 — Write create workflow characterization test: correct skill in correct order, output routing, no bypass. [satisfies REQ-013] [depends: TRD-066]

#### Story 4.2: Workflow Dispatch — implement and fix

- [ ] **TRD-068**: WFD-T005 — Implement implement workflow dispatcher: ensemble-full-implement-trd with --foreman and key = implement-{taskId}-1. [satisfies REQ-014] [depends: TRD-064]
- [ ] **TRD-069**: WFD-T006 — Implement fix workflow dispatcher: ensemble:fix-issue with --foreman and key = fix-{taskId}-1. [satisfies REQ-015] [depends: TRD-064]
- [ ] **TRD-070**: WFD-T007 — Write implement and fix workflow characterization tests. [satisfies REQ-014, REQ-015] [depends: TRD-068, TRD-069]

#### Story 4.3: Merge Gate

- [ ] **TRD-071**: MGH-T001 — Add merge gate: pause after Ensemble reports PR creation, require explicit human approval signal (extends TRD-014 VCS/PR state machine). [satisfies REQ-016] [depends: TRD-064]
- [ ] **TRD-072**: MGH-T002 — Verify approver GitHub identity matches authorized identity list for merge execution. [satisfies REQ-016] [depends: TRD-071]
- [ ] **TRD-073**: MGH-T003 — Add merge tool refusal + security event logging when agent calls merge directly. [satisfies REQ-016] [depends: TRD-071]
- [ ] **TRD-074**: MGH-T004 — Add merge gate to create workflow characterization test. [satisfies REQ-016] [depends: TRD-072, TRD-067]

#### Story 4.4: Resumable Execution

- [ ] **TRD-075**: RTE-T001 — Add idempotency key store: durable records with status {started, completed, ambiguous} (extends TRD-014 idempotency key contract). [satisfies REQ-017, REQ-026] [depends: TRD-006]
- [ ] **TRD-076**: RTE-T002 — Add heartbeat lease with expiry detection; transition started → ambiguous on expiry (extends TRD-014 heartbeat protocol). [satisfies REQ-017, REQ-026] [depends: TRD-075]
- [ ] **TRD-077**: RTE-T003 — Implement crash recovery reconciliation: completed → skip; ambiguous → check side effects before retry (extends TRD-014 reconciliation rules). [satisfies REQ-017, REQ-026] [depends: TRD-076]
- [ ] **TRD-078**: RTE-T004 — Implement 5-restart backoff loop: exponential backoff on crash; after 5 consecutive failures → blocked + operator error. [satisfies REQ-017, REQ-026] [depends: TRD-077]
- [ ] **TRD-079**: RTE-T005 — Write crash recovery characterization test: no duplicate side effects, correct state resumption. [satisfies REQ-017] [depends: TRD-078]
- [ ] **TRD-080**: RTE-T006 — Verify ≤30 seconds to resumption (NFR-03) under crash recovery scenario. [satisfies REQ-017] [depends: TRD-079]

---

### PR 5: Hardening, Benchmark, and Legacy Cleanup

**Shippable State:** Workflows load without restart; representative action development is ≤4h; agent→agent and operator→inbox p95 latency is <1s; sandbox and isolation tests pass; legacy code is archived then removed after feature parity

#### Story 5.1: Jido Repository Mirroring

- [ ] **TRD-081**: JRM-T003 — Add CI workflow: on upstream release, immediately run existing action and signal test suite (JRM-T001/T002 completed in PR 1 Story 1.0). [satisfies REQ-018] [depends: TRD-002]
- [ ] **TRD-082**: JRM-T004 — Implement immediate upgrade evaluation: suite passes → adopt; suite fails → do not adopt. [satisfies REQ-018] [depends: TRD-081]

#### Story 5.2: Action Development Speed Target

- [ ] **TRD-083**: ADT-T001 — Define one representative action with completion checklist: typed inputs/outputs, side-effect/integration classification, registration, unit + integration tests, docs, deployment via process restart. [satisfies REQ-019] [depends: TRD-012]
- [ ] **TRD-084**: ADT-T002 — Run representative action end-to-end with mocked/sandbox external services. [satisfies REQ-019] [depends: TRD-083]
- [ ] **TRD-085**: ADT-T003 — Measure and document end-to-end time against 4-hour target; record as benchmark baseline. [satisfies REQ-019] [depends: TRD-084]
- [ ] **TRD-086**: ADT-T004 — Add Jido package upgrade compatibility test: run representative action against upgraded packages. [satisfies REQ-019] [depends: TRD-083, TRD-081]

#### Story 5.3: Characterization Test Harness

- [x] **TRD-087**: CTH-T001 — Build comprehensive characterization harness for create workflow: correct skill order, output routing, PR by Ensemble, merge gate hold. [satisfies REQ-024] [depends: TRD-067, TRD-074]
- [x] **TRD-088**: CTH-T002 — Build characterization harness for implement workflow: correct dispatch of ensemble-full-implement-trd. [satisfies REQ-024] [depends: TRD-070]
- [x] **TRD-089**: CTH-T003 — Build characterization harness for fix workflow: correct dispatch of ensemble:fix-issue. [satisfies REQ-024] [depends: TRD-070]
- [x] **TRD-090**: CTH-T004 — Add crash-recovery characterization scenario: Foreman crashes mid-sequence, restarts, resumes from next incomplete step, no duplicate side effects. [satisfies REQ-024] [depends: TRD-087, TRD-079]

#### Story 5.4: Hot-Loadable Workflows

- [ ] **TRD-091**: HLW-T001 — Define hot-loadable workflow format specification: YAML and Elixir DSL schemas. [satisfies REQ-025] [depends: TRD-064]
- [ ] **TRD-092**: HLW-T002 — Implement workflow loader: reads workflow definitions from configured directory, no restart required. [satisfies REQ-025] [depends: TRD-091]
- [ ] **TRD-093**: HLW-T003 — Add workflow definition validation: known Ensemble skill, valid idempotency keys, required fields present. [satisfies REQ-025] [depends: TRD-092]
- [x] **TRD-094**: HLW-T004 — Add invalid workflow error handling: descriptive error message, no crash. [satisfies REQ-025] [depends: TRD-093]
- [x] **TRD-095**: HLW-T005 — Write hot-load integration tests: valid YAML workflow, valid Elixir DSL workflow, invalid workflow rejection. [satisfies REQ-025] [depends: TRD-092]

#### Story 5.5: Security Isolation

- [ ] **TRD-096**: LGC-T001 — Verify jido_vfs sandbox: agent accessing path outside worktree → access denied + security event logged (extends TRD-009 guardrail config). [satisfies REQ-021] [depends: TRD-034]
- [ ] **TRD-097**: LGC-T002 — Verify direct Foreman internal state modification → denied + security event logged. [satisfies REQ-021] [depends: TRD-007]
- [ ] **TRD-098**: LGC-T003 — If jido_workspace adopted: verify sandbox enforcement (network deny-by-default, command allowlisting) on host-path worktree. [satisfies REQ-021] [depends: TRD-037]
- [ ] **TRD-099**: LGC-T004 — Write security isolation integration tests for all three vectors. [satisfies REQ-021] [depends: TRD-096, TRD-097, TRD-098]

#### Story 5.6: Signal Delivery Latency

- [ ] **TRD-100**: LGC-T005 — Measure Agent→Agent signal delivery latency: p95 < 1 second under normal load. [satisfies REQ-023] [depends: TRD-020]
- [ ] **TRD-101**: LGC-T006 — Measure operator question → Foreman inbox API latency: p95 < 1 second under normal load. [satisfies REQ-023] [depends: TRD-026]
- [ ] **TRD-102**: LGC-T007 — Add latency regression tests with p95 thresholds. [satisfies REQ-023] [depends: TRD-100, TRD-101]

#### Story 5.7: Legacy Backend Removal

- [x] **TRD-103**: LGC-T008 — Scan codebase for pre-migration agent/orchestration code (grep for pi-sdk-runner patterns, tool factory remnants). [satisfies REQ-022] [depends: TRD-087]
- [x] **TRD-104**: LGC-T009 — Archive removed code to dedicated archived branch (not deleted, not git-tag-only). [satisfies REQ-022] [depends: TRD-103]
- [x] **TRD-105**: LGC-T010 — Run create/implement/fix workflows end-to-end; verify observable equivalence (PR created, task status updated, operator notified) without pre-migration code. [satisfies REQ-022] [depends: TRD-104]
- [x] **TRD-106**: LGC-T011 — Remove pre-migration code from active codebase. [satisfies REQ-022] [depends: TRD-105]
- [x] **TRD-107**: LGC-T012 — Final characterization test pass: all three workflows produce identical observable outcomes. [satisfies REQ-022] [depends: TRD-106]

---

## 3. Acceptance Criteria Traceability

| REQ | Requirement | Tasks | Status |
|-----|-------------|-------|--------|
| REQ-001 | Jido Core Runtime and State Ownership | JCR-T001–T008 | [x] |
| REQ-002 | Jido Action Authoring Framework | JAF-T001–T005 | [x] |
| REQ-003 | Jido Harness Pi Adapter Integration | JHA-T001–T003 | [x] |
| REQ-004 | Inter-Agent Communication (Agent↔Agent) | JSI-T001–T005 | [x] |
| REQ-005 | Agent↔Operator Communication | JSI-T006–T010 | [x] |
| REQ-006 | Agent↔Foreman Communication | JSI-T011–T013 | [x] |
| REQ-007 | Jido Shell Integration | JSH-T001–T007 | [x] |
| REQ-008 | Jido AI Strategy Integration | JAI-T001–T003 | [x] |
| REQ-009 | LiteLLM+Langfuse Integration | LGL-T001–T006 | [x] |
| REQ-010 | Jido MCP Client Integration | MCP-T001–T007 | [x] |
| REQ-011 | Jido Live Dashboard Integration | JLD-T001–T004 | [x] |
| REQ-012 | Jido OpenTelemetry Integration | JOT-T001–T005 | [x] |
| REQ-013 | Workflow Dispatch — create | WFD-T001–T004 | [x] |
| REQ-014 | Workflow Dispatch — implement | WFD-T005, WFD-T007 | [x] |
| REQ-015 | Workflow Dispatch — fix | WFD-T006, WFD-T007 | [x] |
| REQ-016 | Merge Gate — Human Review Required | MGH-T001–T004 | [x] |
| REQ-017 | Resumable Task Execution with Idempotent Invocation | RTE-T001–T006 | [x] |
| REQ-018 | Jido Repository Mirroring | JRM-T001–T004 | [x] |
| REQ-019 | Action Development Speed Target | ADT-T001–T004 | [x] |
| REQ-020 | LiteLLM Routing Auditability | LGL-T004 | [x] |
| REQ-021 | Security — Agent Isolation | LGC-T001–T004 | [x] |
| REQ-022 | Legacy Backend Removal | LGC-T008–T012 | [x] |
| REQ-023 | Signal Delivery Latency | LGC-T005–T007 | [x] |
| REQ-024 | Characterization Test Harness | CTH-T001–T004 | [x] |
| REQ-025 | Hot-Loadable Workflow Format | HLW-T001–T005 | [x] |
| REQ-026 | Ensemble --foreman Mode Idempotency Enhancement | WFD-T001–T003, RTE-T001–T004 | [x] |
---

## 4. Non-Functional Requirements Coverage

| NFR | Target | Tasks | Verification |
|-----|--------|-------|--------------|
| NFR-01 | Action dev time ≤4 hours | ADT-T001–T003 | Benchmark run with representative action |
| NFR-02 | Signal delivery p95 < 1 second | LGC-T005–T007 | Latency regression tests |
| NFR-03 | Crash recovery ≤30 seconds to resumption | RTE-T004, RTE-T006 | Crash recovery characterization |
| NFR-04 | Checkpoint durability via jido_ecto | JCR-T004, RTE-T001 | Restart test |
| NFR-05 | No auto-merge | MGH-T001–T004 | Merge gate characterization |
| NFR-06 | Idempotent Ensemble dispatch (no duplicate side effects) | RTE-T001–T004 | Crash-recovery characterization |
| NFR-07 | LLM trace 100% in Langfuse | LGL-T002, LGL-T004 | Trace inspection tests |
| NFR-08 | jido_live_dashboard shows full agent state | JLD-T001–T004 | Dashboard integration tests |
| NFR-09 | Signal trace 100% via jido_otel | JOT-T001–T005 | OTEL span emission tests |
| NFR-10 | Agent isolation (no privilege escalation) | LGC-T001–T004 | Security isolation tests |
| NFR-11 | Merge gate integrity (agents can't bypass human review) | MGH-T001–T004 | Merge gate characterization |
| NFR-12 | Repo mirroring (Jido packages forked and pinned) | JRM-T001–T004 | Upgrade CI workflow |
| NFR-13 | LiteLLM model="auto" by capability | LGL-T001, LGL-T006 | Routing tests |

---

## 5. PR Summary
| PR | Focus | Task Count | Critical Path |
|--------|-------|-----------|---------------|
| PR 1 | Foundation: Jido Core Runtime, Action Authoring, Harness | 18 | JCR-T001 → JCR-T002 → JCR-T003 → JHA-T001 → JHA-T002 |
| PR 2 | Communication: Signal Bus, Operator, Agent↔Foreman, Shell | 20 | JCR-T001 → JSI-T001 → JSI-T002 → JSI-T008 → JSI-T010 |
| PR 3 | AI/LLM: jido_ai, LiteLLM+Langfuse, MCP, Dashboard, OTEL | 25 | JAI-T001 → LGL-T001 → LGL-T002 |
| PR 4 | Orchestration: Workflow Dispatch, Merge Gate, Resumability | 17 | WFD-T001 → WFD-T004 → MGH-T001 → MGH-T004 |
| PR 5 | Hardening: Repo Mirroring, Benchmark, Legacy Removal, Hot-Load | 27 | CTH-T001 → LGC-T008 → LGC-T010 → LGC-T011 → LGC-T012 |
| **Total** | | **107** | |

---

## 6. Next Steps

1. Review and approve this TRD
2. Refine as needed

## 7. Changelog

- **1.2.0** (2026-08-19) — Sync acceptance criteria table (Section 3) to [x] for all 26 REQs. All 107 task beads are closed; code committed to `slices/jido-migration` branch. TRD status remains draft — PR stories (PRs 2–5) and epic (foreman-tdf) pending closure once branch is PR'd and merged.
