---
document_id: TRD-2026-4212be7e
label: trd-jido-migration
kind: trd
version: 1.1.0
date: 2026-08-18
status: draft
prd_reference: PRD-2026-4212be7e
source_prd_label: prd-jido-migration
design_readiness_score: 5.0
total_tasks: 107
---

# TRD-2026-4212be7e: Jido Agent Ecosystem Migration — Technical Requirements

## Document Metadata

| Field | Value |
|-------|-------|
| **Document ID** | TRD-2026-4212be7e |
| **Label** | trd-jido-migration |
| **Kind** | trd |
| **Version** | 1.1.0 |
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

## 2. Master Task List

**Domain prefixes:** `JCR`=Jido Core Runtime, `JAF`=Jido Action Framework, `JHA`=Jido Harness Adapter, `JSI`=Signal Integration, `JSH`=Shell/VFS, `JAI`=Jido AI, `LGL`=LiteLLM/Langfuse, `MCP`=MCP Client, `JLD`=Live Dashboard, `JOT`=OpenTelemetry, `WFD`=Workflow Dispatch, `MGH`=Merge Gate, `RTE`=Resumability, `JRM`=Jido Repo Mirroring, `ADT`=Action Dev Target, `CTH`=Characterization Harness, `HLW`=Hot-Loadable Workflows, `LGC`=Legacy + Security.

All `Status` cells are `[ ]`.

---

### PR 1: Foundation — Jido Core Runtime and Action Authoring

**Shippable State:** Jido agent starts, executes registered actions, checkpoints state to Postgres, and recovers after restart

#### Story 1.0: Jido Repo Preparation (prerequisite — all packages forked and pinned before integration)

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JRM-T001 | Fork all required Jido repos under Sunstone-Partners GitHub organization | 2h | | [x] |
| JRM-T002 | For each forked Jido repo, select and record the fork URL and specific commit revision for each package; JCR-T001 declares these in mix.exs | 2h | JRM-T001 | [x] |

#### Story 1.1: Jido Core Runtime

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JCR-T001 | Add all Jido packages to mix.exs: jido, jido_action, jido_signal, jido_shell, jido_vfs, jido_ai, jido_harness, jido_ecto, req_llm, jido_otel — every package is sourced from a Sunstone-Partners fork pinned to a specific revision | 2h | JRM-T002 | [x] |
| JCR-T002 | Create Jido.Agent GenServer under Foreman.Application supervision tree with OTP restart strategy | 4h | JCR-T001 | [x] |
| JCR-T003 | Implement cmd/2 loop in Jido agent: action in → updated agent struct + directives out | 4h | JCR-T002 | [ ] |
| JCR-T004 | Integrate jido_ecto for agent struct and checkpoint persistence (Postgres adapter) | 4h | JCR-T002 | [x] |
| JCR-T005 | Implement signal-to-command adapter: Phoenix subscriber for foreman/commands topic, normalizes CloudEvent to ExternalTriggerCommand, routes to TRD-014 Integration Ingestion | 6h | JCR-T001 | [x] |
| JCR-T006 | Write unit tests for Jido.Agent GenServer lifecycle (start, cmd/2, checkpoint, restart) | 4h | JCR-T004 | [ ] |
| JCR-T007 | Write integration test verifying agent signal → command envelope → event store → projection update flow | 4h | JCR-T005 | [ ] |
| JCR-T008 | Write unit tests for signal-to-command adapter in isolation: CloudEvent envelope parsing, topic routing, ExternalTriggerCommand normalization, error handling for malformed CloudEvents | 4h | JCR-T005 | [ ] |

#### Story 1.2: Jido Action Authoring Framework

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JAF-T001 | Define Jido.Action behaviour for tool registration and validation | 3h | JCR-T001 | [x] |
| JAF-T002 | Migrate existing TypeScript tool factories to Jido.Action modules (git_status, diff_read, task_get, etc.) | 8h | JAF-T001 | [x] |
| JAF-T003 | Add action validation middleware (parameter checking before execution) | 2h | JAF-T001 | [ ] |
| JAF-T004 | Add Jido.Character prompt template loader for skills (prompt fragments, not actions) | 3h | JCR-T001 | [x] |
| JAF-T005 | Write isolation tests for each migrated action achieving ≥85% code coverage | 4h | JAF-T002 | [x] |

#### Story 1.3: Jido Harness Pi Adapter

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JHA-T001 | Integrate jido_harness with Jido.Harness.Adapters.Pi | 4h | JCR-T001 | [x] |
| JHA-T002 | Replace pi-sdk-runner.ts with Jido.Harness.Session, Jido.Harness.Run, Jido.Harness.Process | 8h | JHA-T001 | [x] |
| JHA-T003 | Write harness characterization test: verify Jido.Harness.Adapters.Pi creates Jido.Harness.Session, resolves tools through Jido.Harness.Process, and provides Jido.Harness.Run — without asserting legacy pi-sdk-runner.ts behavioral equivalence | 4h | JHA-T002 | [x] |

---

### PR 2: Communication Infrastructure — Signal Bus, Operator, Agent↔Foreman

**Shippable State:** Agent receives operator questions, publishes directives, and Foreman inbox reflects signal delivery — within configurable per-workflow timeouts

#### Story 2.1: Signal Bus (jido_signal)

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JSI-T001 | Configure jido_signal topics: foreman/commands, foreman/operator, foreman/inbox, agents/<agent-id>/directive | 2h | JCR-T001 | [ ] |
| JSI-T002 | Implement Agent→Agent signal pub/sub via Bus.publish to agents/<phase> topic | 4h | JSI-T001 | [ ] |
| JSI-T003 | Implement missing-subscriber configurable policy (silent/warn/error, default warn) in Foreman config | 3h | JSI-T001 | [ ] |
| JSI-T004 | Add signal journal for replay on restart | 4h | JSI-T001 | [ ] |
| JSI-T005 | Write integration tests for signal pub/sub with all three missing-subscriber policies | 3h | JSI-T003 | [ ] |

#### Story 2.2: Operator Communication

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JSI-T006 | Add foreman/operator topic subscriber | 3h | JSI-T001 | [x] |
| JSI-T007 | Implement jido_signal dispatch adapter (webhook/HTTP) to Foreman inbox API | 4h | JSI-T006 | [x] |
| JSI-T008 | Implement operator question → inbox domain event → projector → agent directive flow | 4h | JSI-T007 | [ ] |
| JSI-T009 | Implement per-workflow operator timeout (configurable in workflow definition; mark task blocked on expiry) | 3h | JSI-T008 | [ ] |
| JSI-T010 | Write integration test for operator question → inbox notification → agent resume | 4h | JSI-T008 | [ ] |

#### Story 2.3: Agent↔Foreman Communication

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JSI-T011 | Implement directive publisher (Foreman→Agent) via Bus.publish to agents/<agent-id>/directive | 3h | JSI-T001 | [x] |
| JSI-T012 | Implement task metadata query signal (Agent→Foreman) and response signal (Foreman→Agent) | 3h | JSI-T011 | [ ] |
| JSI-T013 | Write integration tests for nudge and query flows | 3h | JSI-T011, JSI-T012 | [ ] |

#### Story 2.4: Shell Integration

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JSH-T001 | Integrate jido_shell for command execution with jido_vfs sandbox | 4h | JSI-T001 | [ ] |
| JSH-T002 | Implement shell session lifecycle: shell tied to agent lifetime (terminates on agent restart; restarted agent creates new session) | 3h | JSH-T001 | [ ] |
| JSH-T003 | Add VFS isolation per worktree (each agent gets sandboxed filesystem view) | 3h | JSH-T001 | [ ] |
| JSH-T004 | Write shell integration tests: command execution, session isolation, VFS sandbox | 4h | JSH-T002, JSH-T003 | [ ] |

#### Story 2.5: jido_workspace Validation Spike

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JSH-T005 | Spike jido_workspace worktree binding and sandbox enforcement: evaluate in-memory VFS, snapshot semantics, host-path adapter | 8h | JCR-T001 | [ ] |
| JSH-T006 | If spike passes: adopt jido_workspace with validated sandbox policies. If spike fails: use jido_shell + jido_vfs + custom host-path adapter | 4h | JSH-T005 | [ ] |
| JSH-T007 | Document jido_workspace validation result in spike report | 2h | JSH-T005 | [ ] |

---

### PR 3: AI, LLM, and External Integrations

**Shippable State:** Agent routes LLM calls through LiteLLM gateway, MCP tools appear in agent toolset, LiveDashboard shows agent state with ≤1s latency, and all LLM/cmd/signal calls emit OTEL spans to Langfuse

#### Story 3.1: Jido AI + req_llm

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JAI-T001 | Integrate jido_ai strategies (ReAct, Chain-of-Thought) with req_llm HTTP client | 4h | JCR-T001 | [ ] |
| JAI-T002 | Add LLM timeout/error handling: req_llm error → error directive to agent (retry or escalate) | 3h | JAI-T001 | [ ] |
| JAI-T003 | Verify jido_ai routes LLM calls through LiteLLM gateway when configured | 2h | JAI-T001, LGL-T001 | [ ] |

#### Story 3.2: LiteLLM + Langfuse Integration

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| LGL-T001 | Integrate litellm-langfuse-stack (LiteLLM port 4000, Langfuse port 3000) with model="auto" capability routing | 4h | JAI-T001 | [ ] |
| LGL-T002 | Add Langfuse tracing for all LLM calls (prompt, response, model, cost, latency) | 3h | LGL-T001 | [ ] |
| LGL-T003 | Implement zero-candidates failure: LiteLLM returns descriptive error listing excluded filters when all models filtered out; task marked blocked | 2h | LGL-T001 | [ ] |
| LGL-T004 | Add routing auditability: metadata.routed_to and routing reason in every Langfuse trace | 3h | LGL-T002 | [ ] |
| LGL-T005 | Implement LiteLLM unavailable → blocked task (no direct API key fallback) | 2h | LGL-T001 | [ ] |
| LGL-T006 | Write LiteLLM integration tests: auto-routing, budget failover, zero-candidates, unavailable | 4h | LGL-T001 | [ ] |

#### Story 3.3: MCP Client Integration

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| MCP-T001 | Verify jido_mcp fork URL and pinned commit revision from JRM-T002 dependency manifest; confirm fork exists under Sunstone-Partners and revision is accessible | 1h | JRM-T002 | [ ] |
| MCP-T002 | Integrate jido_mcp client pool with agent toolset sync | 4h | MCP-T001 | [ ] |
| MCP-T003 | Implement MCP tool sync: registered MCP servers' tools appear in agent's available toolset | 4h | MCP-T002 | [ ] |
| MCP-T004 | Add bounded diagnostics for malformed MCP responses (endpoint ID, tool ID, correlation ID, parse/schema error, response size, response hash; no raw body without explicit debug policy) | 3h | MCP-T003 | [ ] |
| MCP-T005 | Add MCP security allowlist: reject calls to tools outside allowlist, log security event | 3h | MCP-T003 | [ ] |
| MCP-T006 | Add recoverable/non-recoverable MCP error handling with retry directive | 3h | MCP-T003 | [ ] |
| MCP-T007 | Write MCP integration tests: tool sync, malformed response, allowlist enforcement | 4h | MCP-T003 | [ ] |

#### Story 3.4: Live Dashboard

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JLD-T001 | Mount jido_live_dashboard in Phoenix endpoint under existing Foreman auth guards | 3h | JCR-T001 | [ ] |
| JLD-T002 | Add dashboard views: active agents, current state, signal history, directive queue | 4h | JLD-T001 | [ ] |
| JLD-T003 | Verify dashboard refresh latency ≤1 second for agent state changes | 2h | JLD-T002 | [ ] |
| JLD-T004 | Write dashboard integration tests: auth guard enforcement, data freshness | 3h | JLD-T002 | [ ] |

#### Story 3.5: OpenTelemetry Integration

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JOT-T001 | Configure jido_otel with Langfuse-compatible OTLP endpoint | 3h | JCR-T001 | [ ] |
| JOT-T002 | Emit OTEL span for every cmd/2 call (action name, parameters, duration) | 2h | JOT-T001 | [ ] |
| JOT-T003 | Emit OTEL span for every LLM call (model, token counts, cost, routing reason) | 2h | JOT-T001 | [ ] |
| JOT-T004 | Emit OTEL span for signal publish/dispatch (signal type, topic, delivery status) | 2h | JOT-T001 | [ ] |
| JOT-T005 | Write OTEL integration tests: span emission for cmd/2, LLM calls, signal dispatch | 3h | JOT-T002, JOT-T003, JOT-T004 | [ ] |

---

### PR 4: Workflow Dispatch, Merge Gate, and Resumability

**Shippable State:** create/implement/fix dispatch runs in correct order, resumes idempotently after crashes, and cannot merge without authorized human approval

#### Story 4.1: Workflow Dispatch — create

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| WFD-T001 | Implement create workflow sequential dispatcher: ensemble:create-prd → refine-prd → create-trd → refine-trd → implement-trd | 6h | JSI-T010, JSI-T011 | [ ] |
| WFD-T002 | Add idempotency key management per step: key = create-prd-{taskId}-{step} | 4h | WFD-T001 | [ ] |
| WFD-T003 | Add step sequencing with terminal status propagation (completed/failed/blocked) | 4h | WFD-T002 | [ ] |
| WFD-T004 | Write create workflow characterization test: correct skill in correct order, output routing, no bypass | 4h | WFD-T003 | [ ] |

#### Story 4.2: Workflow Dispatch — implement and fix

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| WFD-T005 | Implement implement workflow dispatcher: ensemble-full-implement-trd with --foreman and key = implement-{taskId}-1 | 4h | WFD-T001 | [ ] |
| WFD-T006 | Implement fix workflow dispatcher: ensemble:fix-issue with --foreman and key = fix-{taskId}-1 | 4h | WFD-T001 | [ ] |
| WFD-T007 | Write implement and fix workflow characterization tests | 4h | WFD-T005, WFD-T006 | [ ] |

#### Story 4.3: Merge Gate

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| MGH-T001 | Add merge gate: pause after Ensemble reports PR creation, require explicit human approval signal (extends TRD-014 VCS/PR state machine) | 4h | WFD-T001 | [ ] |
| MGH-T002 | Verify approver GitHub identity matches authorized identity list for merge execution | 3h | MGH-T001 | [ ] |
| MGH-T003 | Add merge tool refusal + security event logging when agent calls merge directly | 2h | MGH-T001 | [ ] |
| MGH-T004 | Add merge gate to create workflow characterization test | 2h | MGH-T002, WFD-T004 | [ ] |

#### Story 4.4: Resumable Execution

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| RTE-T001 | Add idempotency key store: durable records with status {started, completed, ambiguous} (extends TRD-014 idempotency key contract) | 6h | JCR-T004 | [ ] |
| RTE-T002 | Add heartbeat lease with expiry detection; transition started → ambiguous on expiry (extends TRD-014 heartbeat protocol) | 4h | RTE-T001 | [ ] |
| RTE-T003 | Implement crash recovery reconciliation: completed → skip; ambiguous → check side effects before retry (extends TRD-014 reconciliation rules) | 6h | RTE-T002 | [ ] |
| RTE-T004 | Implement 5-restart backoff loop: exponential backoff on crash; after 5 consecutive failures → blocked + operator error | 4h | RTE-T003 | [ ] |
| RTE-T005 | Write crash recovery characterization test: no duplicate side effects, correct state resumption | 4h | RTE-T004 | [ ] |
| RTE-T006 | Verify ≤30 seconds to resumption (NFR-03) under crash recovery scenario | 2h | RTE-T005 | [ ] |

---
### PR 5: Hardening, Benchmark, and Legacy Cleanup

**Shippable State:** Workflows load without restart; representative action development is ≤4h; agent→agent and operator→inbox p95 latency is <1s; sandbox and isolation tests pass; legacy code is archived then removed after feature parity

#### Story 5.1: Jido Repository Mirroring

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| JRM-T003 | Add CI workflow: on upstream release, immediately run existing action and signal test suite (JRM-T001/T002 completed in PR 1 Story 1.0) | 4h | JRM-T002 | [ ] |
| JRM-T004 | Implement immediate upgrade evaluation: suite passes → adopt; suite fails → do not adopt | 4h | JRM-T003 | [ ] |

#### Story 5.2: Action Development Speed Target

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| ADT-T001 | Define one representative action with completion checklist: typed inputs/outputs, side-effect/integration classification, registration, unit + integration tests, docs, deployment via process restart | 2h | JAF-T002 | [ ] |
| ADT-T002 | Run representative action end-to-end with mocked/sandbox external services | 4h | ADT-T001 | [ ] |
| ADT-T003 | Measure and document end-to-end time against 4-hour target; record as benchmark baseline | 2h | ADT-T002 | [ ] |
| ADT-T004 | Add Jido package upgrade compatibility test: run representative action against upgraded packages | 3h | ADT-T001, JRM-T003 | [ ] |

#### Story 5.3: Characterization Test Harness

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| CTH-T001 | Build comprehensive characterization harness for create workflow: correct skill order, output routing, PR by Ensemble, merge gate hold | 8h | WFD-T004, MGH-T004 | [ ] |
| CTH-T002 | Build characterization harness for implement workflow: correct dispatch of ensemble-full-implement-trd | 4h | WFD-T007 | [ ] |
| CTH-T003 | Build characterization harness for fix workflow: correct dispatch of ensemble:fix-issue | 4h | WFD-T007 | [ ] |
| CTH-T004 | Add crash-recovery characterization scenario: Foreman crashes mid-sequence, restarts, resumes from next incomplete step, no duplicate side effects | 6h | CTH-T001, RTE-T005 | [ ] |

#### Story 5.4: Hot-Loadable Workflows

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| HLW-T001 | Define hot-loadable workflow format specification: YAML and Elixir DSL schemas | 6h | WFD-T001 | [ ] |
| HLW-T002 | Implement workflow loader: reads workflow definitions from configured directory, no restart required | 6h | HLW-T001 | [ ] |
| HLW-T003 | Add workflow definition validation: known Ensemble skill, valid idempotency keys, required fields present | 4h | HLW-T002 | [ ] |
| HLW-T004 | Add invalid workflow error handling: descriptive error message, no crash | 3h | HLW-T003 | [ ] |
| HLW-T005 | Write hot-load integration tests: valid YAML workflow, valid Elixir DSL workflow, invalid workflow rejection | 4h | HLW-T002 | [ ] |

#### Story 5.5: Security Isolation

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| LGC-T001 | Verify jido_vfs sandbox: agent accessing path outside worktree → access denied + security event logged (extends TRD-009 guardrail config) | 3h | JSH-T003 | [ ] |
| LGC-T002 | Verify direct Foreman internal state modification → denied + security event logged | 3h | JCR-T005 | [ ] |
| LGC-T003 | If jido_workspace adopted: verify sandbox enforcement (network deny-by-default, command allowlisting) on host-path worktree | 3h | JSH-T006 | [ ] |
| LGC-T004 | Write security isolation integration tests for all three vectors | 4h | LGC-T001, LGC-T002, LGC-T003 | [ ] |

#### Story 5.6: Signal Delivery Latency

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| LGC-T005 | Measure Agent→Agent signal delivery latency: p95 < 1 second under normal load | 3h | JSI-T002 | [ ] |
| LGC-T006 | Measure operator question → Foreman inbox API latency: p95 < 1 second under normal load | 3h | JSI-T008 | [ ] |
| LGC-T007 | Add latency regression tests with p95 thresholds | 2h | LGC-T005, LGC-T006 | [ ] |

#### Story 5.7: Legacy Backend Removal

| id | task | Est. | Deps | Status |
|----|------|------|------|--------|
| LGC-T008 | Scan codebase for pre-migration agent/orchestration code (grep for pi-sdk-runner patterns, tool factory remnants) | 4h | CTH-T001 | [ ] |
| LGC-T009 | Archive removed code to dedicated archived branch (not deleted, not git-tag-only) | 3h | LGC-T008 | [ ] |
| LGC-T010 | Run create/implement/fix workflows end-to-end; verify observable equivalence (PR created, task status updated, operator notified) without pre-migration code | 4h | LGC-T009 | [ ] |
| LGC-T011 | Remove pre-migration code from active codebase | 8h | LGC-T010 | [ ] |
| LGC-T012 | Final characterization test pass: all three workflows produce identical observable outcomes | 4h | LGC-T011 | [ ] |

---

## 3. Acceptance Criteria Traceability

| REQ | Requirement | Tasks | Status |
|-----|-------------|-------|--------|
| REQ-001 | Jido Core Runtime and State Ownership | JCR-T001–T008 | [ ] |
| REQ-002 | Jido Action Authoring Framework | JAF-T001–T005 | [ ] |
| REQ-003 | Jido Harness Pi Adapter Integration | JHA-T001–T003 | [x] |
| REQ-004 | Inter-Agent Communication (Agent↔Agent) | JSI-T001–T005 | [ ] |
| REQ-005 | Agent↔Operator Communication | JSI-T006–T010 | [ ] |
| REQ-006 | Agent↔Foreman Communication | JSI-T011–T013 | [ ] |
| REQ-007 | Jido Shell Integration | JSH-T001–T007 | [ ] |
| REQ-008 | Jido AI Strategy Integration | JAI-T001–T003 | [ ] |
| REQ-009 | LiteLLM+Langfuse Integration | LGL-T001–T006 | [ ] |
| REQ-010 | Jido MCP Client Integration | MCP-T001–T007 | [ ] |
| REQ-011 | Jido Live Dashboard Integration | JLD-T001–T004 | [ ] |
| REQ-012 | Jido OpenTelemetry Integration | JOT-T001–T005 | [ ] |
| REQ-013 | Workflow Dispatch — create | WFD-T001–T004 | [ ] |
| REQ-014 | Workflow Dispatch — implement | WFD-T005, WFD-T007 | [ ] |
| REQ-015 | Workflow Dispatch — fix | WFD-T006, WFD-T007 | [ ] |
| REQ-016 | Merge Gate — Human Review Required | MGH-T001–T004 | [ ] |
| REQ-017 | Resumable Task Execution with Idempotent Invocation | RTE-T001–T006 | [ ] |
| REQ-018 | Jido Repository Mirroring | JRM-T001–T004 | [ ] |
| REQ-019 | Action Development Speed Target | ADT-T001–T004 | [ ] |
| REQ-020 | LiteLLM Routing Auditability | LGL-T004 | [ ] |
| REQ-021 | Security — Agent Isolation | LGC-T001–T004 | [ ] |
| REQ-022 | Legacy Backend Removal | LGC-T008–T012 | [ ] |
| REQ-023 | Signal Delivery Latency | LGC-T005–T007 | [ ] |
| REQ-024 | Characterization Test Harness | CTH-T001–T004 | [ ] |
| REQ-025 | Hot-Loadable Workflow Format | HLW-T001–T005 | [ ] |
| REQ-026 | Ensemble --foreman Mode Idempotency Enhancement | WFD-T001–T003, RTE-T001–T004 | [ ] |

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
