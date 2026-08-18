---
document_id: TRD-2026-4212be7e
label: trd-jido-migration
kind: trd
version: 1.0.0
status: draft
date: 2026-08-18
prd_reference: PRD-2026-4212be7e
source_prd_label: prd-jido-migration
design_readiness_score: 5.0
total_tasks: 106
---

# TRD-2026-4212be7e: Jido Agent Ecosystem Migration — Technical Requirements

## Document Metadata

| Field | Value |
| **Document ID** | TRD-2026-4212be7e |
| **Label** | trd-jido-migration |
| **Kind** | trd |
| **Version** | 1.0.0 |
| **Status** | draft |
| **Date** | 2026-08-18 |
| **PRD Reference** | PRD-2026-4212be7e |
| **Source PRD Label** | prd-jido-migration |
| **Design Readiness Score** | 5.0 |
| **Total Tasks** | 108 |

---

## 0. Reused Capabilities

This migration extends existing Foreman infrastructure defined in TRD-2026-014 (Elixir Backend Orchestration). No capability is duplicated.

### Reused from TRD-2026-014

| Capability | TRD-014 Location | How Extended |
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
| Guardrail config (ProjectConfig) | TRD-009-001 | `jido_vfs` sandbox policies extend the same config shape for VFS access control |
| Security event logging | TRD-009-003, §4.6 | New security vectors: MCP allowlist violations, direct Foreman internal state access, jido_workspace sandbox bypass |
| Heartbeat manager | TRD-009-006 | Replaced by Jido agent lifecycle heartbeat with `jido_ecto` checkpoint persistence |

### Extended from TRD-2026-015

| Capability | TRD-015 Location | How Extended |
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

### Sprint 1: Foundation — Jido Core Runtime and Action Authoring

#### Story 1.1: Jido Core Runtime

- [ ] **TRD-JCR-T001**: Add all Jido packages to mix.exs: jido, jido_action, jido_signal, jido_shell, jido_vfs, jido_ai, jido_harness, jido_ecto, req_llm, jido_otel (Est: 2h)
- [ ] **TRD-JCR-T002**: Create Jido.Agent GenServer under Foreman.Application supervision tree with OTP restart strategy (Est: 4h) [depends: TRD-JCR-T001]
- [ ] **TRD-JCR-T003**: Implement cmd/2 loop in Jido agent: action in → updated agent struct + directives out (Est: 4h) [depends: TRD-JCR-T002]
- [ ] **TRD-JCR-T004**: Integrate jido_ecto for agent struct and checkpoint persistence (Postgres adapter) (Est: 4h) [depends: TRD-JCR-T002]
- [ ] **TRD-JCR-T005**: Implement signal-to-command adapter: Phoenix subscriber for foreman/commands topic, normalizes CloudEvent to ExternalTriggerCommand, routes to TRD-014 Integration Ingestion (Est: 6h) [depends: TRD-JCR-T001]
- [ ] **TRD-JCR-T006**: Write unit tests for Jido.Agent GenServer lifecycle (start, cmd/2, checkpoint, restart) (Est: 4h) [depends: TRD-JCR-T004]
- [ ] **TRD-JCR-T007**: Write integration test verifying agent signal → command envelope → event store → projection update flow (Est: 4h) [depends: TRD-JCR-T005]

#### Story 1.2: Jido Action Authoring Framework

- [ ] **TRD-JAF-T001**: Define Jido.Action behaviour for tool registration and validation (Est: 3h) [depends: TRD-JCR-T001]
- [ ] **TRD-JAF-T002**: Migrate existing TypeScript tool factories to Jido.Action modules (git_status, diff_read, task_get, etc.) (Est: 8h) [depends: TRD-JAF-T001]
- [ ] **TRD-JAF-T003**: Add action validation middleware (parameter checking before execution) (Est: 2h) [depends: TRD-JAF-T001]
- [ ] **TRD-JAF-T004**: Add Jido.Character prompt template loader for skills (prompt fragments, not actions) (Est: 3h) [depends: TRD-JCR-T001]
- [ ] **TRD-JAF-T005**: Write isolation tests for each migrated action achieving ≥85% code coverage (Est: 4h) [depends: TRD-JAF-T002]

#### Story 1.3: Jido Harness Pi Adapter

- [ ] **TRD-JHA-T001**: Integrate jido_harness with Jido.Harness.Adapters.Pi (Est: 4h) [depends: TRD-JCR-T001]
- [ ] **TRD-JHA-T002**: Replace pi-sdk-runner.ts with Jido.Harness.Session, Jido.Harness.Run, Jido.Harness.Process (Est: 8h) [depends: TRD-JHA-T001]
- [ ] **TRD-JHA-T003**: Write characterization test verifying Jido.Harness.Adapters.Pi provides functional equivalent of pi-sdk-runner.ts session lifecycle (Est: 4h) [depends: TRD-JHA-T002]

---

### Sprint 2: Communication Infrastructure — Signal Bus, Operator, Agent↔Foreman

#### Story 2.1: Signal Bus (jido_signal)

- [ ] **TRD-JSI-T001**: Configure jido_signal topics: foreman/commands, foreman/operator, foreman/inbox, agents/<agent-id>/directive (Est: 2h) [depends: TRD-JCR-T001]
- [ ] **TRD-JSI-T002**: Implement Agent→Agent signal pub/sub via Bus.publish to agents/<phase> topic (Est: 4h) [depends: TRD-JSI-T001]
- [ ] **TRD-JSI-T003**: Implement missing-subscriber configurable policy (silent/warn/error, default warn) in Foreman config (Est: 3h) [depends: TRD-JSI-T001]
- [ ] **TRD-JSI-T004**: Add signal journal for replay on restart (Est: 4h) [depends: TRD-JSI-T001]
- [ ] **TRD-JSI-T005**: Write integration tests for signal pub/sub with all three missing-subscriber policies (Est: 3h) [depends: TRD-JSI-T003]

#### Story 2.2: Operator Communication

- [ ] **TRD-JSI-T006**: Add foreman/operator topic subscriber (Est: 3h) [depends: TRD-JSI-T001]
- [ ] **TRD-JSI-T007**: Implement jido_signal dispatch adapter (webhook/HTTP) to Foreman inbox API (Est: 4h) [depends: TRD-JSI-T006]
- [ ] **TRD-JSI-T008**: Implement operator question → inbox domain event → projector → agent directive flow (Est: 4h) [depends: TRD-JSI-T007]
- [ ] **TRD-JSI-T009**: Implement per-workflow operator timeout (configurable in workflow definition; mark task blocked on expiry) (Est: 3h) [depends: TRD-JSI-T008]
- [ ] **TRD-JSI-T010**: Write integration test for operator question → inbox notification → agent resume (Est: 4h) [depends: TRD-JSI-T008]

#### Story 2.3: Agent↔Foreman Communication

- [ ] **TRD-JSI-T011**: Implement directive publisher (Foreman→Agent) via Bus.publish to agents/<agent-id>/directive (Est: 3h) [depends: TRD-JSI-T001]
- [ ] **TRD-JSI-T012**: Implement task metadata query signal (Agent→Foreman) and response signal (Foreman→Agent) (Est: 3h) [depends: TRD-JSI-T011]
- [ ] **TRD-JSI-T013**: Write integration tests for nudge and query flows (Est: 3h) [depends: TRD-JSI-T011, TRD-JSI-T012]

#### Story 2.4: Shell Integration

- [ ] **TRD-JSH-T001**: Integrate jido_shell for command execution with jido_vfs sandbox (Est: 4h) [depends: TRD-JSI-T001]
- [ ] **TRD-JSH-T002**: Implement shell session lifecycle: shell tied to agent lifetime (terminates on agent restart; restarted agent creates new session) (Est: 3h) [depends: TRD-JSH-T001]
- [ ] **TRD-JSH-T003**: Add VFS isolation per worktree (each agent gets sandboxed filesystem view) (Est: 3h) [depends: TRD-JSH-T001]
- [ ] **TRD-JSH-T004**: Write shell integration tests: command execution, session isolation, VFS sandbox (Est: 4h) [depends: TRD-JSH-T002, TRD-JSH-T003]

#### Story 2.5: jido_workspace Validation Spike

- [ ] **TRD-JSH-T005**: Spike jido_workspace worktree binding and sandbox enforcement: evaluate in-memory VFS, snapshot semantics, host-path adapter (Est: 8h) [depends: TRD-JCR-T001]
- [ ] **TRD-JSH-T006**: If spike passes: adopt jido_workspace with validated sandbox policies. If spike fails: use jido_shell + jido_vfs + custom host-path adapter (Est: 4h) [depends: TRD-JSH-T005]
- [ ] **TRD-JSH-T007**: Document jido_workspace validation result in spike report (Est: 2h) [depends: TRD-JSH-T005]

---

### Sprint 3: AI, LLM, and External Integrations

#### Story 3.1: Jido AI + req_llm

- [ ] **TRD-JAI-T001**: Integrate jido_ai strategies (ReAct, Chain-of-Thought) with req_llm HTTP client (Est: 4h) [depends: TRD-JCR-T001]
- [ ] **TRD-JAI-T002**: Add LLM timeout/error handling: req_llm error → error directive to agent (retry or escalate) (Est: 3h) [depends: TRD-JAI-T001]
- [ ] **TRD-JAI-T003**: Verify jido_ai routes LLM calls through LiteLLM gateway when configured (Est: 2h) [depends: TRD-JAI-T001, TRD-LGL-T001]

#### Story 3.2: LiteLLM + Langfuse Integration

- [ ] **TRD-LGL-T001**: Integrate litellm-langfuse-stack (LiteLLM port 4000, Langfuse port 3000) with model="auto" capability routing (Est: 4h) [depends: TRD-JAI-T001]
- [ ] **TRD-LGL-T002**: Add Langfuse tracing for all LLM calls (prompt, response, model, cost, latency) (Est: 3h) [depends: TRD-LGL-T001]
- [ ] **TRD-LGL-T003**: Implement zero-candidates failure: LiteLLM returns descriptive error listing excluded filters when all models filtered out; task marked blocked (Est: 2h) [depends: TRD-LGL-T001]
- [ ] **TRD-LGL-T004**: Add routing auditability: metadata.routed_to and routing reason in every Langfuse trace (Est: 3h) [depends: TRD-LGL-T002]
- [ ] **TRD-LGL-T005**: Implement LiteLLM unavailable → blocked task (no direct API key fallback) (Est: 2h) [depends: TRD-LGL-T001]
- [ ] **TRD-LGL-T006**: Write LiteLLM integration tests: auto-routing, budget failover, zero-candidates, unavailable (Est: 4h) [depends: TRD-LGL-T001]

#### Story 3.3: MCP Client Integration

- [ ] **TRD-MCP-T001**: Fork jido_mcp under Sunstone-Partners GitHub and pin to specific git revision (Est: 2h)
- [ ] **TRD-MCP-T002**: Integrate jido_mcp client pool with agent toolset sync (Est: 4h) [depends: TRD-MCP-T001]
- [ ] **TRD-MCP-T003**: Implement MCP tool sync: registered MCP servers' tools appear in agent's available toolset (Est: 4h) [depends: TRD-MCP-T002]
- [ ] **TRD-MCP-T004**: Add bounded diagnostics for malformed MCP responses (endpoint ID, tool ID, correlation ID, parse/schema error, response size, response hash; no raw body without explicit debug policy) (Est: 3h) [depends: TRD-MCP-T003]
- [ ] **TRD-MCP-T005**: Add MCP security allowlist: reject calls to tools outside allowlist, log security event (Est: 3h) [depends: TRD-MCP-T003]
- [ ] **TRD-MCP-T006**: Add recoverable/non-recoverable MCP error handling with retry directive (Est: 3h) [depends: TRD-MCP-T003]
- [ ] **TRD-MCP-T007**: Write MCP integration tests: tool sync, malformed response, allowlist enforcement (Est: 4h) [depends: TRD-MCP-T003]

#### Story 3.4: Live Dashboard

- [ ] **TRD-JLD-T001**: Mount jido_live_dashboard in Phoenix endpoint under existing Foreman auth guards (Est: 3h) [depends: TRD-JCR-T001]
- [ ] **TRD-JLD-T002**: Add dashboard views: active agents, current state, signal history, directive queue (Est: 4h) [depends: TRD-JLD-T001]
- [ ] **TRD-JLD-T003**: Verify dashboard refresh latency ≤1 second for agent state changes (Est: 2h) [depends: TRD-JLD-T002]
- [ ] **TRD-JLD-T004**: Write dashboard integration tests: auth guard enforcement, data freshness (Est: 3h) [depends: TRD-JLD-T002]

#### Story 3.5: OpenTelemetry Integration

- [ ] **TRD-JOT-T001**: Configure jido_otel with Langfuse-compatible OTLP endpoint (Est: 3h) [depends: TRD-JCR-T001]
- [ ] **TRD-JOT-T002**: Emit OTEL span for every cmd/2 call (action name, parameters, duration) (Est: 2h) [depends: TRD-JOT-T001]
- [ ] **TRD-JOT-T003**: Emit OTEL span for every LLM call (model, token counts, cost, routing reason) (Est: 2h) [depends: TRD-JOT-T001]
- [ ] **TRD-JOT-T004**: Emit OTEL span for signal publish/dispatch (signal type, topic, delivery status) (Est: 2h) [depends: TRD-JOT-T001]
- [ ] **TRD-JOT-T005**: Write OTEL integration tests: span emission for cmd/2, LLM calls, signal dispatch (Est: 3h) [depends: TRD-JOT-T002, TRD-JOT-T003, TRD-JOT-T004]

---

### Sprint 4: Workflow Dispatch, Merge Gate, and Resumability

#### Story 4.1: Workflow Dispatch — create

- [ ] **TRD-WFD-T001**: Implement create workflow sequential dispatcher: ensemble:create-prd → refine-prd → create-trd → refine-trd → implement-trd (Est: 6h) [depends: TRD-JSI-T010, TRD-JSI-T011]
- [ ] **TRD-WFD-T002**: Add idempotency key management per step: key = create-prd-{taskId}-{step} (Est: 4h) [depends: TRD-WFD-T001]
- [ ] **TRD-WFD-T003**: Add step sequencing with terminal status propagation (completed/failed/blocked) (Est: 4h) [depends: TRD-WFD-T002]
- [ ] **TRD-WFD-T004**: Write create workflow characterization test: correct skill in correct order, output routing, no bypass (Est: 4h) [depends: TRD-WFD-T003]

#### Story 4.2: Workflow Dispatch — implement and fix

- [ ] **TRD-WFD-T005**: Implement implement workflow dispatcher: ensemble-full-implement-trd with --foreman and key = implement-{taskId}-1 (Est: 4h) [depends: TRD-WFD-T001]
- [ ] **TRD-WFD-T006**: Implement fix workflow dispatcher: ensemble:fix-issue with --foreman and key = fix-{taskId}-1 (Est: 4h) [depends: TRD-WFD-T001]
- [ ] **TRD-WFD-T007**: Write implement and fix workflow characterization tests (Est: 4h) [depends: TRD-WFD-T005, TRD-WFD-T006]

#### Story 4.3: Merge Gate

- [ ] **TRD-MGH-T001**: Add merge gate: pause after Ensemble reports PR creation, require explicit human approval signal (extends TRD-014 VCS/PR state machine) (Est: 4h) [depends: TRD-WFD-T001]
- [ ] **TRD-MGH-T002**: Verify approver GitHub identity matches authorized identity list for merge execution (Est: 3h) [depends: TRD-MGH-T001]
- [ ] **TRD-MGH-T003**: Add merge tool refusal + security event logging when agent calls merge directly (Est: 2h) [depends: TRD-MGH-T001]
- [ ] **TRD-MGH-T004**: Add merge gate to create workflow characterization test (Est: 2h) [depends: TRD-MGH-T002, TRD-WFD-T004]

#### Story 4.4: Resumable Execution

- [ ] **TRD-RTE-T001**: Add idempotency key store: durable records with status {started, completed, ambiguous} (extends TRD-014 idempotency key contract) (Est: 6h) [depends: TRD-JCR-T004]
- [ ] **TRD-RTE-T002**: Add heartbeat lease with expiry detection; transition started → ambiguous on expiry (extends TRD-014 heartbeat protocol) (Est: 4h) [depends: TRD-RTE-T001]
- [ ] **TRD-RTE-T003**: Implement crash recovery reconciliation: completed → skip; ambiguous → check side effects before retry (extends TRD-014 reconciliation rules) (Est: 6h) [depends: TRD-RTE-T002]
- [ ] **TRD-RTE-T004**: Implement 5-restart backoff loop: exponential backoff on crash; after 5 consecutive failures → blocked + operator error (Est: 4h) [depends: TRD-RTE-T003]
- [ ] **TRD-RTE-T005**: Write crash recovery characterization test: no duplicate side effects, correct state resumption (Est: 4h) [depends: TRD-RTE-T004]
- [ ] **TRD-RTE-T006**: Verify ≤30 seconds to resumption (NFR-03) under crash recovery scenario (Est: 2h) [depends: TRD-RTE-T005]

---

### Sprint 5: Hardening, Benchmark, and Legacy Cleanup

#### Story 5.1: Jido Repository Mirroring

- [ ] **TRD-JRM-T001**: Fork all required Jido repos under Sunstone-Partners GitHub organization (Est: 2h)
- [ ] **TRD-JRM-T002**: Pin all mix.exs Jido dependencies to specific git revisions (no floating versions) (Est: 2h) [depends: TRD-JRM-T001]
- [ ] **TRD-JRM-T003**: Add CI workflow: on upstream release, immediately run existing action and signal test suite (Est: 4h) [depends: TRD-JRM-T002]
- [ ] **TRD-JRM-T004**: Implement immediate upgrade evaluation: suite passes → adopt; suite fails → do not adopt (Est: 4h) [depends: TRD-JRM-T003]

#### Story 5.2: Action Development Speed Target

- [ ] **TRD-ADT-T001**: Define one representative action with completion checklist: typed inputs/outputs, side-effect/integration classification, registration, unit + integration tests, docs, deployment via process restart (Est: 2h) [depends: TRD-JAF-T002]
- [ ] **TRD-ADT-T002**: Run representative action end-to-end with mocked/sandbox external services (Est: 4h) [depends: TRD-ADT-T001]
- [ ] **TRD-ADT-T003**: Measure and document end-to-end time against 4-hour target; record as benchmark baseline (Est: 2h) [depends: TRD-ADT-T002]
- [ ] **TRD-ADT-T004**: Add Jido package upgrade compatibility test: run representative action against upgraded packages (Est: 3h) [depends: TRD-ADT-T001, TRD-JRM-T003]

#### Story 5.3: Characterization Test Harness

- [ ] **TRD-CTH-T001**: Build comprehensive characterization harness for create workflow: correct skill order, output routing, PR by Ensemble, merge gate hold (Est: 8h) [depends: TRD-WFD-T004, TRD-MGH-T004]
- [ ] **TRD-CTH-T002**: Build characterization harness for implement workflow: correct dispatch of ensemble-full-implement-trd (Est: 4h) [depends: TRD-WFD-T007]
- [ ] **TRD-CTH-T003**: Build characterization harness for fix workflow: correct dispatch of ensemble:fix-issue (Est: 4h) [depends: TRD-WFD-T007]
- [ ] **TRD-CTH-T004**: Add crash-recovery characterization scenario: Foreman crashes mid-sequence, restarts, resumes from next incomplete step, no duplicate side effects (Est: 6h) [depends: TRD-CTH-T001, TRD-RTE-T005]

#### Story 5.4: Hot-Loadable Workflows

- [ ] **TRD-HLW-T001**: Define hot-loadable workflow format specification: YAML and Elixir DSL schemas (Est: 6h) [depends: TRD-WFD-T001]
- [ ] **TRD-HLW-T002**: Implement workflow loader: reads workflow definitions from configured directory, no restart required (Est: 6h) [depends: TRD-HLW-T001]
- [ ] **TRD-HLW-T003**: Add workflow definition validation: known Ensemble skill, valid idempotency keys, required fields present (Est: 4h) [depends: TRD-HLW-T002]
- [ ] **TRD-HLW-T004**: Add invalid workflow error handling: descriptive error message, no crash (Est: 3h) [depends: TRD-HLW-T003]
- [ ] **TRD-HLW-T005**: Write hot-load integration tests: valid YAML workflow, valid Elixir DSL workflow, invalid workflow rejection (Est: 4h) [depends: TRD-HLW-T002]

#### Story 5.5: Security Isolation

- [ ] **TRD-LGC-T001**: Verify jido_vfs sandbox: agent accessing path outside worktree → access denied + security event logged (extends TRD-009 guardrail config) (Est: 3h) [depends: TRD-JSH-T003]
- [ ] **TRD-LGC-T002**: Verify direct Foreman internal state modification → denied + security event logged (Est: 3h) [depends: TRD-JCR-T005]
- [ ] **TRD-LGC-T003**: If jido_workspace adopted: verify sandbox enforcement (network deny-by-default, command allowlisting) on host-path worktree (Est: 3h) [depends: TRD-JSH-T006]
- [ ] **TRD-LGC-T004**: Write security isolation integration tests for all three vectors (Est: 4h) [depends: TRD-LGC-T001, TRD-LGC-T002, TRD-LGC-T003]

#### Story 5.6: Signal Delivery Latency

- [ ] **TRD-LGC-T005**: Measure Agent→Agent signal delivery latency: p95 < 1 second under normal load (Est: 3h) [depends: TRD-JSI-T002]
- [ ] **TRD-LGC-T006**: Measure operator question → Foreman inbox API latency: p95 < 1 second under normal load (Est: 3h) [depends: TRD-JSI-T008]
- [ ] **TRD-LGC-T007**: Add latency regression tests with p95 thresholds (Est: 2h) [depends: TRD-LGC-T005, TRD-LGC-T006]

#### Story 5.7: Legacy Backend Removal

- [ ] **TRD-LGC-T008**: Scan codebase for pre-migration agent/orchestration code (grep for pi-sdk-runner patterns, tool factory remnants) (Est: 4h) [depends: TRD-CTH-T001]
- [ ] **TRD-LGC-T009**: Archive removed code to dedicated archived branch (not deleted, not git-tag-only) (Est: 3h) [depends: TRD-LGC-T008]
- [ ] **TRD-LGC-T010**: Run create/implement/fix workflows end-to-end; verify observable equivalence (PR created, task status updated, operator notified) without pre-migration code (Est: 4h) [depends: TRD-LGC-T009]
- [ ] **TRD-LGC-T011**: Remove pre-migration code from active codebase (Est: 8h) [depends: TRD-LGC-T010]
- [ ] **TRD-LGC-T012**: Final characterization test pass: all three workflows produce identical observable outcomes (Est: 4h) [depends: TRD-LGC-T011]

---

## 3. Acceptance Criteria Traceability

| REQ | Requirement | Tasks | Status |
| REQ-001 | Jido Core Runtime and State Ownership | JCR-T001–T007 | [ ] |
| REQ-002 | Jido Action Authoring Framework | JAF-T001–T005 | [ ] |
| REQ-003 | Jido Harness Pi Adapter Integration | JHA-T001–T003 | [ ] |
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
| NFR-01: Action dev time | ≤4 hours | ADT-T001–T003 | Benchmark run with representative action |
| NFR-02: Signal latency | p95 < 1 second | LGC-T005–T007 | Latency regression tests |
| NFR-03: Crash recovery | ≤30 seconds resumption | RTE-T004, RTE-T006 | Crash recovery characterization |
| NFR-04: Checkpoint durability | Agent state survives restart via jido_ecto | JCR-T004, RTE-T001 | Restart test |
| NFR-05: No auto-merge | Human approval always | MGH-T001–T004 | Merge gate characterization |
| NFR-06: LiteLLM required | No direct API fallback | LGL-T005 | Unavailable-LiteLLM test |
| NFR-07: 85% coverage | New actions ≥85% | JAF-T005 | ExUnit coverage report |
| NFR-08: Workflow format | YAML + Elixir DSL hot-load | HLW-T001–T005 | Hot-load integration tests |
| NFR-09: Idempotent dispatch | Durable started/completed/ambiguous | RTE-T001–T004 | Crash-recovery characterization |
| NFR-10: Auditability | Every model="auto" trace in Langfuse | LGL-T002, LGL-T004 | Trace inspection tests |
| NFR-11: Security isolation | Sandbox enforcement active | LGC-T001–T004 | Security isolation tests |
| NFR-12: Agent↔Foreman signals | Signal → command envelope → event store | JCR-T005, JSI-T011–T013 | Integration tests |
| NFR-13: LiteLLM capability routing | model="auto" by cheapest capable | LGL-T001, LGL-T006 | Routing tests |

---

## 5. Sprint Summary

| Sprint | Focus | Task Count | Critical Path |
| Sprint 1 | Foundation: Jido Core Runtime, Action Authoring, Harness | 15 | JCR-T001 → JCR-T002 → JCR-T003 → JHA-T001 → JHA-T002 |
| Sprint 2 | Communication: Signal Bus, Operator, Agent↔Foreman, Shell | 20 | JCR-T001 → JSI-T001 → JSI-T002 → JSI-T008 → JSI-T010 |
| Sprint 3 | AI/LLM: jido_ai, LiteLLM+Langfuse, MCP, Dashboard, OTEL | 25 | JAI-T001 → LGL-T001 → LGL-T002 |
| Sprint 4 | Orchestration: Workflow Dispatch, Merge Gate, Resumability | 17 | WFD-T001 → WFD-T004 → MGH-T001 → MGH-T004 |
| Sprint 5 | Hardening: Repo Mirroring, Benchmark, Legacy Removal, Hot-Load | 29 | CTH-T001 → LGC-T008 → LGC-T010 → LGC-T011 → LGC-T012 |
| **Total** | | **106** | |

---

## 6. Next Steps

1. Review and approve this TRD
2. Run `foreman sling prd docs/PRD/PRD-2026-4212be7e-jido-migration.md` to create native Foreman tasks from the PRD
3. Proceed to implementation following Sprint 1 task order
