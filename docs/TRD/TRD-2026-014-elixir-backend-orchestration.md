---
document_id: TRD-2026-014
prd_reference: PRD-2026-014
prd_path: docs/PRD/PRD-2026-014-elixir-backend-orchestration.md
version: 1.0.5
status: Draft
date: 2026-06-16
design_readiness_score: 4.75
design_gate: PASS
architecture_choice: Option B - Full OTP orchestration core
---

# TRD-2026-014: Elixir Backend Orchestration Migration

## 1. PRD Validation Summary

Source PRD: `docs/PRD/PRD-2026-014-elixir-backend-orchestration.md`.

Validation result: PASS.

| Check | Result |
|-------|--------|
| PRD readiness score | 4.63 / 5.0 |
| REQ IDs | 25 requirements, REQ-001 through REQ-025, sequential |
| Acceptance criteria | 76 ACs, all co-located under parent requirements |
| Given/When/Then format | PASS |
| Must requirements with >=2 ACs | PASS |
| Constraints and non-goals | Present |
| NFRs | Performance, reliability, security, observability, maintainability present |

## 2. Domain Analysis

| Domain | Requirements |
|--------|--------------|
| Runtime / OTP supervision | REQ-001, REQ-008, REQ-011, REQ-012 |
| Data / CQRS / projections | REQ-002, REQ-003, REQ-010, REQ-015, REQ-017, REQ-022 |
| CLI / API | REQ-004, REQ-005, REQ-023 |
| Worker and provider execution | REQ-006, REQ-007, REQ-009, REQ-018, REQ-019 |
| VCS / PR / merge | REQ-013, REQ-014 |
| Integrations / migration | REQ-016, REQ-020 |
| Testing / docs / architecture validation | REQ-021, REQ-024, REQ-025 |

Project type: brownfield. Existing TypeScript Foreman codebase remains source for CLI behavior, workflow semantics, VCS behavior, and compatibility until the Elixir server reaches parity.

## 3. Architecture Decision

Chosen approach: **Option B — Full OTP orchestration core**.

Foreman will move orchestration ownership to an Elixir/OTP server as the target architecture from the start. Node remains as CLI/runtime edge and Pi SDK worker layer, but the Elixir server owns durable commands, events, projections, supervisors, run/phase actors, recovery, VCS/PR state machines, and integration command ingestion.

**Spike result:** TRD-001 completed the comparative architecture spike in `docs/spikes/TRD-2026-014-architecture-spike.md`. The spike compared Elixir/OTP, WolverineFx/Marten, and a TypeScript control alternative against the same Foreman lifecycle and worker-crash recovery scenario. It confirmed Elixir/OTP remains the target backend because OTP supervision best matches Foreman's local long-running worker/process orchestration model, while WolverineFx/Marten's durable inbox/outbox, saga, scheduled-message, dead-letter, and event-store strengths do not remove the need for custom local worker supervision.

### 3.1 Alternatives Considered

| Option | Summary | Pros | Cons | Decision |
|--------|---------|------|------|----------|
| A: Thin hybrid slice | Event store + one run state machine first; Node keeps most orchestration | Smallest initial change, easiest rollback | Defers hardest recovery/PR/state ownership risks | Rejected by user selection |
| B: Full OTP orchestration core | Elixir owns all orchestration domains from the target design | Clearest boundaries, strongest recovery model, avoids dual truth | Larger migration, more upfront work | **Selected** |
| C: Spike-gated hybrid | Architecture spike first, then vertical hybrid slices | Balanced and PRD-aligned | Slower to full ownership | Not selected |

The comparative spike is complete. Implementation may proceed beyond TRD-001 under the Elixir/OTP target architecture unless a future TRD explicitly revises the runtime decision.

## 4. System Architecture

### 4.1 Component Diagram

```text
Node CLI
  ├─ command parsing, output rendering, compatibility aliases
  ├─ local server bootstrap
  └─ authenticated HTTP over localhost/default configured remote
        │
        ▼
Elixir Foreman Server
  ├─ HTTP API and auth boundary
  ├─ Command handlers
  ├─ Append-only event store
  ├─ Projection workers and rebuild tools
  ├─ ProjectSupervisor / RunSupervisor / WorkerSupervisor
  ├─ RunServer and PhaseServer state machines
  ├─ Scheduler and capacity manager
  ├─ Recovery/reconciliation supervisor
  ├─ VCS/PR/merge state machines
  ├─ Inbox, logs, debug, status/watch projections
  └─ Integration command ingestion
        │
        ▼
Node/Pi SDK Worker Layer
  ├─ HTTP worker protocol over localhost
  ├─ Pi SDK createAgentSession execution
  ├─ tool-call bridge and event streaming
  └─ attach/session metadata where supported
        │
        ▼
External Systems
  ├─ Postgres event store + projections
  ├─ Git/Jujutsu worktrees and branches
  ├─ GitHub PR/check APIs and CodeRabbit gates
  ├─ Jira/GitHub/sentinel trigger sources
  └─ filesystem logs/artifacts
```

### 4.2 Component Responsibilities

| Component | Responsibility | Interface / Data Format |
|-----------|----------------|--------------------------|
| Node CLI | Parse commands, render projections, bootstrap local server | HTTP JSON commands/responses |
| Elixir HTTP API | Auth, command routing, streaming endpoints | JSON over HTTP; SSE/WebSocket may be added after v1 |
| Command Handlers | Validate intent, append events, reject invalid state | Typed command structs and event envelopes |
| Event Store | Durable source of orchestration truth | Postgres append-only table with `event_type`, `schema_version`, `payload`, `metadata` |
| Projection Workers | Maintain read models for CLI/watch/board/debug/inbox | Postgres projection tables with rebuild checkpoints |
| RunServer / PhaseServer | Own explicit run/phase state transitions | OTP messages backed by durable events |
| Scheduler | Claim ready tasks under capacity limits | Command/event API plus task/run projections |
| WorkerSupervisor | Start/monitor Node/Pi workers | HTTP worker contract + heartbeat metadata |
| Recovery Supervisor | Reconcile event state with OS/worktree/PR reality | Observed external-state records converted to reconciliation events |
| VCS/PR Services | Encapsulate Git/Jujutsu and PR gate behavior | Adapter interfaces with event-backed results |
| Integration Ingestion | Normalize sentinel/Jira/GitHub triggers | Idempotent commands with external dedupe keys |

### 4.3 Data Flow

1. User runs a Node CLI command.
2. CLI starts or locates the Elixir server, authenticates, and sends a JSON command.
3. Elixir validates command state and appends domain events before updating projections.
4. Supervisors start or route to project/run/phase actors.
5. Worker-required phases start Node/Pi SDK workers through the worker HTTP protocol.
6. Workers stream tool, log, heartbeat, artifact, and phase-result events to Elixir.
7. Projections update status/watch/board/inbox/log/debug views.
8. Recovery compares durable state with external reality and emits reconciliation events after crashes or drift.

### 4.4 Technology Choices

| Area | Choice | Rationale |
|------|--------|-----------|
| Server runtime | Elixir/OTP | Supervision, actors, crash recovery, long-running local orchestration fit |
| Durable store | Postgres | Existing Foreman dependency, event/projection persistence |
| CLI | Node/TypeScript | Preserve npm distribution and existing operator UX |
| Worker runtime | Node/Pi SDK | Preserve Pi SDK semantics and current tool execution |
| Transport | HTTP over localhost by default, authenticated remote when configured | Matches PRD resolved decision and keeps tooling simple |
| Worker protocol | HTTP over localhost | Explicit, contract-testable, easy Node/Elixir boundary |

### 4.5 API, Event, and Worker Contracts

#### Command API Envelope

All Node CLI to Elixir server calls use authenticated JSON over HTTP.

```json
{
  "command_id": "uuid",
  "command_type": "RunStart",
  "schema_version": 1,
  "payload": {},
  "metadata": {
    "project_id": "string",
    "actor": "cli|integration|worker",
    "correlation_id": "uuid",
    "idempotency_key": "string"
  }
}
```

Successful responses use:

```json
{
  "ok": true,
  "events": ["event_id"],
  "projection_version": 123,
  "correlation_id": "uuid"
}
```

Errors use:

```json
{
  "ok": false,
  "error": {
    "code": "VALIDATION_FAILED|CONFLICT|UNAUTHORIZED|UNSUPPORTED|INTERNAL",
    "message": "human readable summary",
    "details": {},
    "retryable": false,
    "correlation_id": "uuid"
  }
}
```

#### Event Store Envelope

The append-only event table stores:

| Field | Purpose |
|-------|---------|
| `event_id` | globally unique event identifier |
| `stream_id` | aggregate stream, e.g. `run:<id>` or `task:<id>` |
| `stream_version` | optimistic concurrency sequence within stream |
| `event_type` | typed fact name, e.g. `RunStarted` |
| `schema_version` | decoder version |
| `payload` | event-specific JSON payload |
| `metadata` | actor, project, idempotency key, source |
| `occurred_at` | server timestamp |
| `correlation_id` | request/trace identifier |
| `causation_id` | prior command/event that caused this event |

Appends must enforce `(stream_id, stream_version)` uniqueness. Command handlers must reject stale expected versions with `CONFLICT` before side effects. Idempotent commands must persist and check `idempotency_key`.

#### Projection Checkpoints

Each projection records `projection_name`, `last_event_id`, `last_stream_version`, `updated_at`, and optional `rebuild_started_at`. Rebuilds must be idempotent and resumable from checkpoints.

#### Worker Protocol

Elixir controls Node/Pi workers through versioned HTTP endpoints:

| Endpoint | Direction | Purpose |
|----------|-----------|---------|
| `POST /worker/v1/phases/:phase_id/start` | Elixir → worker | start phase with prompt, tools, env contract, report paths |
| `POST /worker/v1/events` | worker → Elixir | stream assistant/tool/log/artifact/phase result events |
| `POST /worker/v1/heartbeat` | worker → Elixir | report liveness, session id, current phase, attach metadata |
| `POST /worker/v1/control` | Elixir → worker | request cancel, pause, resume, attach handoff, graceful shutdown |

All worker messages include `protocol_version`, `run_id`, `phase_id`, `worker_id`, `correlation_id`, and `sequence`. Elixir rejects unknown protocol versions and out-of-order event sequences.

### 4.6 Recovery and Reconciliation Rules

- Reattach if worker heartbeat/session metadata is less than 60 seconds old and the worker answers `/worker/v1/heartbeat` with matching `run_id`, `phase_id`, and `worker_id`.
- Restart from checkpoint only if the phase declares idempotency or a safe checkpoint in workflow metadata.
- Mark the run `NeedsOperator` when external state conflicts cannot be resolved safely by policy.
- Never replay destructive side effects without an idempotency key.
- Reconciliation must emit observation events before resolution events, e.g. `ExternalWorkerObserved` before `WorkerReattached` or `WorkerRestarted`.
- Worktree, PR, branch, and OS process observations are external facts; projections never overwrite them silently.

### 4.7 Test Fixture Contracts

TRD tests should use JSON fixtures under `test/fixtures/elixir-orchestration/`. The TRD defines schemas only; implementation creates the files.

| Fixture | Purpose | Required Fields |
|---------|---------|-----------------|
| `command-run-start-valid.json` | Valid CLI/server command request | `command_id`, `command_type`, `schema_version`, `payload`, `metadata.project_id`, `metadata.correlation_id`, `metadata.idempotency_key` |
| `worker-phase-success.json` | Worker phase lifecycle success | `protocol_version`, `run_id`, `phase_id`, `worker_id`, ordered `events[]`, `sequence` |
| `worker-heartbeat-stale-and-checkpoint.json` | Recovery decision fixture | `run_id`, `phase_id`, `worker_id`, `last_heartbeat_at`, `checkpoint`, `idempotent`, `expected_recovery_action` |
| `integration-jira-transition.json` | External trigger ingestion | `source`, `external_id`, `project_id`, `event_type`, `occurred_at`, `payload`, `idempotency_key` |
| `vcs-pr-ready-state.json` | PR gate and VCS result fixture | `operation_id`, `backend`, `workspace_id`, `status`, `effects`, `pr_gate_state` |

### 4.8 External Integration Command Contract

Integrations normalize external events into `ExternalTriggerCommand`:

```json
{
  "command_type": "ExternalTriggerCommand",
  "source": "jira|github|sentinel",
  "external_id": "string",
  "project_id": "string",
  "event_type": "issue_transition|pull_request|test_failure",
  "occurred_at": "iso-8601",
  "payload": {},
  "idempotency_key": "string"
}
```

Dedupe key formats:

- Jira: `jira:<site>:<issueKey>:<transitionId>`
- GitHub: `github:<repo>:<eventId>`
- Sentinel: `sentinel:<project>:<fingerprint>`

Elixir must reject duplicate `idempotency_key` values without creating duplicate tasks/runs and must emit an idempotent no-op event or response.

### 4.9 VCS and PR Gate Contract

VCS operations return `VcsOperationResult`:

```json
{
  "operation_id": "uuid",
  "backend": "git|jujutsu",
  "workspace_id": "string",
  "status": "ok|failed|conflict|noop",
  "stdout_ref": "artifact-ref|null",
  "stderr_ref": "artifact-ref|null",
  "effects": [],
  "error": null
}
```

PR gate state enum: `unknown`, `pending`, `seen_pending`, `stable_ready`, `failed`, `stale`, `merged`.

Merge orchestration must revalidate `stable_ready` immediately before appending any merge event. A stale or failed revalidation returns `CONFLICT` and records the observed PR gate state.

## 4.10 Quality Requirements

| Quality Attribute | Requirement | Verification |
|-------------------|-------------|--------------|
| Projection latency | `status`, `task list`, and `run show` projection reads return in <250ms for 100 active/recent tasks locally | Integration benchmark with seeded projection rows |
| Event append throughput | Event append path supports >=100 events/sec locally for bursty worker logs/tool events | Event-store load test with ordered stream assertions |
| Worker liveness | Worker heartbeat interval defaults to 10s; worker is stale after 60s without matching heartbeat metadata | Recovery fixture and fake worker tests |
| API error handling | Command API returns structured `{ok:false,error:{code,message,details,retryable,correlation_id}}` envelope for validation, auth, conflict, unsupported, and internal errors | API contract tests |
| Remote access | Remote binding requires explicit config and authentication; localhost remains default | Config and auth integration tests |
| Secrets/log safety | Secrets are redacted from events, logs, projections, and debug timelines | Redaction regression fixtures |

## Master Task List

Each `*-TEST` task must name the exact command or API endpoint exercised, fixture name, expected event(s), expected projection row/view, and failure or recovery assertion where applicable.

### PR 1: Architecture Decision and Server Skeleton

**Shippable State:** Operators can run `foreman server doctor` and receive a real Elixir server readiness report showing project loading, database connectivity, and projection health.
- [x] **TRD-001**: Complete comparative architecture spike and record final stack decision (6h) [satisfies REQ-025]

**Description:** Complete comparative architecture spike with executable lifecycle/recovery prototypes and record final stack decision before production implementation continues.

**Validates PRD ACs:** AC-025-1, AC-025-2, AC-025-3, AC-025-4

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-001-TEST**: Verify Complete comparative architecture spike and record final stack decision (3h) [verifies TRD-001] [satisfies REQ-025] [depends: TRD-001]

**Description:** Add unit/integration tests that verify AC-025-1, AC-025-2, AC-025-3, AC-025-4 for TRD-001.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-002**: Create Elixir application shell and OTP supervision topology (6h) [satisfies REQ-001] [depends: TRD-001]

**Description:** Create Elixir application shell and OTP supervision topology with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-001-1, AC-001-2, AC-001-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-002-TEST**: Verify Create Elixir application shell and OTP supervision topology (3h) [verifies TRD-002] [satisfies REQ-001] [depends: TRD-002]

**Description:** Add unit/integration tests that verify AC-001-1, AC-001-2, AC-001-3 for TRD-002.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-003**: Define Postgres event store schema, event envelopes, and versioned decoders (6h) [satisfies REQ-002] [depends: TRD-002]

**Description:** Define Postgres event store schema, event envelopes, and versioned decoders with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-002-1, AC-002-2, AC-002-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-003-TEST**: Verify Define Postgres event store schema, event envelopes, and versioned decoders (3h) [verifies TRD-003] [satisfies REQ-002] [depends: TRD-003]

**Description:** Add unit/integration tests that verify AC-002-1, AC-002-2, AC-002-3 for TRD-003.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-004**: Implement projection pipeline and rebuild entry points (6h) [satisfies REQ-003] [depends: TRD-003]

**Description:** Implement projection pipeline and rebuild entry points with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-003-1, AC-003-2, AC-003-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-004-TEST**: Verify Implement projection pipeline and rebuild entry points (3h) [verifies TRD-004] [satisfies REQ-003] [depends: TRD-004]

**Description:** Add unit/integration tests that verify AC-003-1, AC-003-2, AC-003-3 for TRD-004.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-005**: Implement authenticated HTTP server API and Node CLI client transport (5h) [satisfies REQ-004, REQ-023] [depends: TRD-002, TRD-004]

**Description:** Implement authenticated HTTP server API and Node CLI client transport with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-004-1, AC-004-3, AC-023-2

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-005-TEST**: Verify Implement authenticated HTTP server API and Node CLI client transport (3h) [verifies TRD-005] [satisfies REQ-004, REQ-023] [depends: TRD-005]

**Description:** Add unit/integration tests that verify AC-004-1, AC-004-3, AC-023-2 for TRD-005.

**Concrete Coverage:** Exercise `POST /api/v1/commands` with fixture `command-run-start-valid.json`; assert `CommandAccepted` or validation error event, `run_projection` version increment, `Authorization` header handling, and `{ok,error}` response envelope shape.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-006**: Implement server bootstrap, health, and CLI auto-start behavior (4h) [satisfies REQ-004, REQ-005] [depends: TRD-005]

**Description:** Implement server bootstrap, health, and CLI auto-start behavior with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-004-3, AC-005-1, AC-005-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-006-TEST**: Verify Implement server bootstrap, health, and CLI auto-start behavior (3h) [verifies TRD-006] [satisfies REQ-004, REQ-005] [depends: TRD-006]

**Description:** Add unit/integration tests that verify AC-004-3, AC-005-1, AC-005-3 for TRD-006.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
### PR 2: CLI, Projects, Tasks, and Scheduling

**Shippable State:** Users can create/list/show tasks and start eligible runs through the new Node CLI backed by Elixir projections.
- [x] **TRD-007**: Implement domain command grouping and legacy alias warnings (5h) [satisfies REQ-005] [depends: TRD-006]

**Description:** Implement domain command grouping and legacy alias warnings with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-005-1, AC-005-2, AC-005-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-007-TEST**: Verify Implement domain command grouping and legacy alias warnings (3h) [verifies TRD-007] [satisfies REQ-005] [depends: TRD-007]

**Description:** Add unit/integration tests that verify AC-005-1, AC-005-2, AC-005-3 for TRD-007.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-008**: Implement task and project command handlers with atomic projections (6h) [satisfies REQ-010] [depends: TRD-005]

**Description:** Implement task and project command handlers with atomic projections with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-010-1, AC-010-2, AC-010-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-008-TEST**: Verify Implement task and project command handlers with atomic projections (3h) [verifies TRD-008] [satisfies REQ-010] [depends: TRD-008]

**Description:** Add unit/integration tests that verify AC-010-1, AC-010-2, AC-010-3 for TRD-008.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-009**: Implement run and phase state machines as OTP actors (6h) [satisfies REQ-008] [depends: TRD-003]

**Description:** Implement run and phase state machines as OTP actors with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-008-1, AC-008-2, AC-008-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-009-TEST**: Verify Implement run and phase state machines as OTP actors (3h) [verifies TRD-009] [satisfies REQ-008] [depends: TRD-009]

**Description:** Add unit/integration tests that verify AC-008-1, AC-008-2, AC-008-3 for TRD-009.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-010**: Implement supervised scheduler and capacity enforcement (6h) [satisfies REQ-011] [depends: TRD-008]

**Description:** Implement supervised scheduler and capacity enforcement with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-011-1, AC-011-2, AC-011-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-010-TEST**: Verify Implement supervised scheduler and capacity enforcement (3h) [verifies TRD-010] [satisfies REQ-011] [depends: TRD-010]

**Description:** Add unit/integration tests that verify AC-011-1, AC-011-2, AC-011-3 for TRD-010.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
### PR 3: Worker Bridge and Workflow Execution

**Shippable State:** Users can run existing YAML workflows through a Node/Pi worker controlled by the Elixir server.
- [x] **TRD-011**: Implement Node/Pi SDK worker HTTP protocol and heartbeat contract (6h) [satisfies REQ-006] [depends: TRD-005]

**Description:** Implement Node/Pi SDK worker HTTP protocol and heartbeat contract with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-006-1, AC-006-2, AC-006-3, AC-006-4

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-011-TEST**: Verify Implement Node/Pi SDK worker HTTP protocol and heartbeat contract (3h) [verifies TRD-011] [satisfies REQ-006] [depends: TRD-011]

**Description:** Add unit/integration tests that verify AC-006-1, AC-006-2, AC-006-3, AC-006-4 for TRD-011.

**Concrete Coverage:** Exercise `POST /worker/v1/phases/:phase_id/start`, `/worker/v1/events`, and `/worker/v1/heartbeat` with fixture `worker-phase-success.json`; assert ordered `WorkerHeartbeat`, `ToolCallFinished`, and `PhaseCompleted` events plus rejection of out-of-order sequence numbers.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-012**: Implement provider adapter registry with Pi-only production enforcement for v1 (4h) [satisfies REQ-007] [depends: TRD-011]

**Description:** Implement provider adapter registry with Pi-only production enforcement for v1 with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-007-1, AC-007-2, AC-007-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-012-TEST**: Verify Implement provider adapter registry with Pi-only production enforcement for v1 (3h) [verifies TRD-012] [satisfies REQ-007] [depends: TRD-012]

**Description:** Add unit/integration tests that verify AC-007-1, AC-007-2, AC-007-3 for TRD-012.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-013**: Migrate workflow YAML interpretation into Elixir state-machine execution (6h) [satisfies REQ-009] [depends: TRD-009, TRD-011]

**Description:** Migrate workflow YAML interpretation into Elixir state-machine execution with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-009-1, AC-009-2, AC-009-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-013-TEST**: Verify Migrate workflow YAML interpretation into Elixir state-machine execution (3h) [verifies TRD-013] [satisfies REQ-009] [depends: TRD-013]

**Description:** Add unit/integration tests that verify AC-009-1, AC-009-2, AC-009-3 for TRD-013.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-014**: Implement deterministic simulation harness for run, phase, and worker events (5h) [satisfies REQ-021] [depends: TRD-009, TRD-011]

**Description:** Implement deterministic simulation harness for run, phase, and worker events with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-021-1, AC-021-2, AC-021-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-014-TEST**: Verify Implement deterministic simulation harness for run, phase, and worker events (3h) [verifies TRD-014] [satisfies REQ-021] [depends: TRD-014]

**Description:** Add unit/integration tests that verify AC-021-1, AC-021-2, AC-021-3 for TRD-014.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
### PR 4: Recovery, VCS, PR Gates, and Inbox

**Shippable State:** Users can recover crashed workers, manage worktrees, observe PR gate state, and exchange inbox messages from event-backed views.
- [x] **TRD-015**: Implement worker recovery and external-state reconciliation engine (6h) [satisfies REQ-012] [depends: TRD-011]

**Description:** Implement worker recovery and external-state reconciliation engine with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-012-1, AC-012-2, AC-012-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-015-TEST**: Verify Implement worker recovery and external-state reconciliation engine (3h) [verifies TRD-015] [satisfies REQ-012] [depends: TRD-015]

**Description:** Add unit/integration tests that verify AC-012-1, AC-012-2, AC-012-3 for TRD-015.

**Concrete Coverage:** Exercise recovery fixture `worker-heartbeat-stale-and-checkpoint.json`; assert `ExternalWorkerObserved` precedes `WorkerRestarted`, reattach occurs only for fresh matching heartbeat metadata, and unresolved conflicts produce `NeedsOperator`.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-016**: Implement VCS and worktree adapters behind server-owned events (6h) [satisfies REQ-013] [depends: TRD-009]

**Description:** Implement VCS and worktree adapters behind server-owned events with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-013-1, AC-013-2, AC-013-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-016-TEST**: Verify Implement VCS and worktree adapters behind server-owned events (3h) [verifies TRD-016] [satisfies REQ-013] [depends: TRD-016]

**Description:** Add unit/integration tests that verify AC-013-1, AC-013-2, AC-013-3 for TRD-016.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-017**: Implement PR gate and merge orchestration state machines (6h) [satisfies REQ-014] [depends: TRD-016]

**Description:** Implement PR gate and merge orchestration state machines with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-014-1, AC-014-2, AC-014-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [x] **TRD-017-TEST**: Verify Implement PR gate and merge orchestration state machines (3h) [verifies TRD-017] [satisfies REQ-014] [depends: TRD-017]

**Description:** Add unit/integration tests that verify AC-014-1, AC-014-2, AC-014-3 for TRD-017.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [x] **TRD-018**: Implement event-backed inbox and agent mail projection (5h) [satisfies REQ-015] [depends: TRD-004]

**Description:** Implement event-backed inbox and agent mail projection with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-015-1, AC-015-2, AC-015-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [ ] **TRD-018-TEST**: Verify Implement event-backed inbox and agent mail projection (3h) [verifies TRD-018] [satisfies REQ-015] [depends: TRD-018]

**Description:** Add unit/integration tests that verify AC-015-1, AC-015-2, AC-015-3 for TRD-018.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
### PR 5: Integrations, Debug, Attach, Planning, and Migration

**Shippable State:** Users can ingest external triggers, debug timelines, attach to supported sessions, run planning flows, and coexist with legacy TS commands.
- [ ] **TRD-019**: Implement sentinel, Jira, and GitHub command ingestion with idempotency (5h) [satisfies REQ-016] [depends: TRD-008]

**Description:** Implement sentinel, Jira, and GitHub command ingestion with idempotency with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-016-1, AC-016-2, AC-016-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [ ] **TRD-019-TEST**: Verify Implement sentinel, Jira, and GitHub command ingestion with idempotency (3h) [verifies TRD-019] [satisfies REQ-016] [depends: TRD-019]

**Description:** Add unit/integration tests that verify AC-016-1, AC-016-2, AC-016-3 for TRD-019.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [ ] **TRD-020**: Implement event-backed logs, reports, and debug timeline views (5h) [satisfies REQ-017] [depends: TRD-004]

**Description:** Implement event-backed logs, reports, and debug timeline views with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-017-1, AC-017-2, AC-017-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [ ] **TRD-020-TEST**: Verify Implement event-backed logs, reports, and debug timeline views (3h) [verifies TRD-020] [satisfies REQ-017] [depends: TRD-020]

**Description:** Add unit/integration tests that verify AC-017-1, AC-017-2, AC-017-3 for TRD-020.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [ ] **TRD-021**: Implement attach and interactive recovery bridge (5h) [satisfies REQ-018] [depends: TRD-011]

**Description:** Implement attach and interactive recovery bridge with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-018-1, AC-018-2, AC-018-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [ ] **TRD-021-TEST**: Verify Implement attach and interactive recovery bridge (3h) [verifies TRD-021] [satisfies REQ-018] [depends: TRD-021]

**Description:** Add unit/integration tests that verify AC-018-1, AC-018-2, AC-018-3 for TRD-021.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [ ] **TRD-022**: Implement PRD/TRD planning flow execution through worker pipeline (5h) [satisfies REQ-019] [depends: TRD-013]

**Description:** Implement PRD/TRD planning flow execution through worker pipeline with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-019-1, AC-019-2, AC-019-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [ ] **TRD-022-TEST**: Verify Implement PRD/TRD planning flow execution through worker pipeline (3h) [verifies TRD-022] [satisfies REQ-019] [depends: TRD-022]

**Description:** Add unit/integration tests that verify AC-019-1, AC-019-2, AC-019-3 for TRD-022.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [ ] **TRD-023**: Implement migration importer and legacy TS coexistence delegation (6h) [satisfies REQ-020] [depends: TRD-003, TRD-008]

**Description:** Implement migration importer and legacy TS coexistence delegation with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-020-1, AC-020-2, AC-020-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [ ] **TRD-023-TEST**: Verify Implement migration importer and legacy TS coexistence delegation (3h) [verifies TRD-023] [satisfies REQ-020] [depends: TRD-023]

**Description:** Add unit/integration tests that verify AC-020-1, AC-020-2, AC-020-3 for TRD-023.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
### PR 6: Operations, Security, and Documentation

**Shippable State:** Operators can safely run the remotely configurable server with auth, metrics, doctor checks, and updated documentation.
- [ ] **TRD-024**: Implement operational metrics, server doctor, and projection lag reporting (5h) [satisfies REQ-022] [depends: TRD-004, TRD-020]

**Description:** Implement operational metrics, server doctor, and projection lag reporting with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-022-1, AC-022-2, AC-022-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [ ] **TRD-024-TEST**: Verify Implement operational metrics, server doctor, and projection lag reporting (3h) [verifies TRD-024] [satisfies REQ-022] [depends: TRD-024]

**Description:** Add unit/integration tests that verify AC-022-1, AC-022-2, AC-022-3 for TRD-024.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [ ] **TRD-025**: Implement worker secret scoping, authorization audit events, and remote access controls (5h) [satisfies REQ-023] [depends: TRD-005, TRD-011]

**Description:** Implement worker secret scoping, authorization audit events, and remote access controls with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-023-1, AC-023-2, AC-023-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [ ] **TRD-025-TEST**: Verify Implement worker secret scoping, authorization audit events, and remote access controls (3h) [verifies TRD-025] [satisfies REQ-023] [depends: TRD-025]

**Description:** Add unit/integration tests that verify AC-023-1, AC-023-2, AC-023-3 for TRD-025.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.
- [ ] **TRD-026**: Update README, User Guide, CLI Reference, and architecture docs (4h) [satisfies REQ-024] [depends: TRD-024]

**Description:** Update README, User Guide, CLI Reference, and architecture docs with production code, migration-safe boundaries, and operator-visible behavior.

**Validates PRD ACs:** AC-024-1, AC-024-2, AC-024-3

**Implementation AC Checklist:**
- Given the feature is configured, when the relevant command/API path is exercised, then the documented behavior succeeds and emits durable events where applicable.
- Given invalid input, missing dependencies, or unsupported state, when the path is exercised, then the system fails before side effects with actionable diagnostics.
- Given the server restarts, when projections or actors are rebuilt, then user-visible state remains consistent with the event store.
- [ ] **TRD-026-TEST**: Verify Update README, User Guide, CLI Reference, and architecture docs (3h) [verifies TRD-026] [satisfies REQ-024] [depends: TRD-026]

**Description:** Add unit/integration tests that verify AC-024-1, AC-024-2, AC-024-3 for TRD-026.

**Verification Steps:**
- Given the happy-path fixture, when the implementation is executed, then the expected command/event/projection result is asserted.
- Given an edge-case fixture, when the implementation is executed, then failure or recovery behavior is asserted without flake-prone sleeps.
- Given test cleanup runs, when the test exits, then no orphan worker, worktree, or DB state remains.

## Team Configuration

> Auto-generated by `ensemble:configure-team` on 2026-06-16. Review and edit assignments if needed before implementation.
>
> Complexity metrics: 52 tasks (26 implementation + 26 test), 218 estimated hours, 8 domains, 52 cross-cutting tasks, dependency depth 8, tier Complex.
>
> Agent discovery note: no `packages/*/agents/*.yaml` registry or `marketplace.json` was found in this repository. Assignments use available built-in pi subagents as safe fallbacks.

```yaml
team:
  tier: Complex
  metrics:
    task_count: 52
    implementation_task_count: 26
    test_task_count: 26
    estimated_hours: 218
    domain_count: 8
    domains:
      - runtime-otp
      - data-cqrs
      - cli-api
      - worker-provider
      - vcs-pr
      - integrations
      - security-ops
      - docs-testing
    domain_task_map:
      runtime-otp: [TRD-002, TRD-009, TRD-010, TRD-015]
      data-cqrs: [TRD-003, TRD-004, TRD-008, TRD-018, TRD-020, TRD-024]
      cli-api: [TRD-005, TRD-006, TRD-007]
      worker-provider: [TRD-011, TRD-012, TRD-013, TRD-014, TRD-021, TRD-022]
      vcs-pr: [TRD-016, TRD-017]
      integrations: [TRD-019, TRD-023]
      security-ops: [TRD-024, TRD-025]
      docs-testing: [TRD-001-TEST through TRD-026-TEST, TRD-026]
    cross_cutting_count: 18
    dependency_depth: 8
  roles:
    - name: lead
      agent: planner
      owns:
        - task-selection
        - architecture-review
        - dependency-sequencing
        - final-approval
    - name: builder
      agents:
        - worker
      owns:
        - implementation
      domains:
        - runtime-otp
        - data-cqrs
        - cli-api
        - worker-provider
        - vcs-pr
        - integrations
        - security-ops
        - docs-testing
    - name: reviewer
      agent: reviewer
      owns:
        - code-review
        - architecture-consistency-review
        - traceability-review
    - name: qa
      agent: worker
      owns:
        - test-implementation
        - validation
        - regression-checks
  marketplace:
    available: false
    installed_during_run: []
    declined_plugins: []
    notes:
      - marketplace.json not found; plugin gap analysis skipped.
      - No package agent registry found; using built-in pi agents only. Replace assignments if project agents are installed later.
```

## 6. Dependency Graph and Critical Path

Critical path: TRD-001 → TRD-002 → TRD-003 → TRD-009 → TRD-016 → TRD-017.

Parallel tracks after TRD-005: CLI/task/scheduler work (TRD-006 through TRD-010), worker/workflow/simulation work (TRD-011 through TRD-014), event-backed views (TRD-018 and TRD-020), integrations (TRD-019), and attach/planning (TRD-021 and TRD-022) can proceed without waiting for the full CLI or recovery chain. Recovery starts after the worker protocol; VCS/PR work starts from the shared state-machine foundation.

No circular dependencies identified.

No implementation task is estimated above 6h. If implementation discovers a task exceeding 8h, split before coding continues.

## 7. Sprint Planning

## Sprint 1: Architecture and Core Runtime

Covers PR 1. Goal: confirm stack, run server, append events, rebuild projections, and exercise CLI server health.

## Sprint 2: User Command Parity

Covers PR 2. Goal: task/project command parity, command grouping, scheduler basics, and projection-backed status.

## Sprint 3: Workflow Execution

Covers PR 3. Goal: Pi SDK worker bridge, adapter registry, workflow execution, and deterministic simulation.

## Sprint 4: Recovery and External Systems

Covers PR 4. Goal: recovery, VCS/worktree state, PR gates, and inbox.

## Sprint 5: Migration and Operations

Covers PRs 5-6. Goal: integrations, debug/attach/planning, coexistence, metrics, security, and docs.

## 8. Acceptance Criteria Traceability

| REQ-NNN | Description | Implementation Tasks | Test Tasks |
|---------|-------------|----------------------|------------|
| REQ-001 | Elixir Server Runtime | TRD-002 | TRD-002-TEST |
| REQ-002 | Durable Event Store | TRD-003 | TRD-003-TEST |
| REQ-003 | CQRS Projections | TRD-004 | TRD-004-TEST |
| REQ-004 | Streamlined Node CLI | TRD-005, TRD-006 | TRD-005-TEST, TRD-006-TEST |
| REQ-005 | Simplified CLI Command Surface | TRD-006, TRD-007 | TRD-006-TEST, TRD-007-TEST |
| REQ-006 | Node/Pi SDK Worker Bridge | TRD-011 | TRD-011-TEST |
| REQ-007 | Provider Adapter Interface | TRD-012 | TRD-012-TEST |
| REQ-008 | Workflow Execution State Machines | TRD-009 | TRD-009-TEST |
| REQ-009 | Existing Workflow Parity | TRD-013 | TRD-013-TEST |
| REQ-010 | Task and Project Management Parity | TRD-008 | TRD-008-TEST |
| REQ-011 | Run Dispatch and Scheduling | TRD-010 | TRD-010-TEST |
| REQ-012 | Recovery and Reconciliation | TRD-015 | TRD-015-TEST |
| REQ-013 | VCS and Worktree Management | TRD-016 | TRD-016-TEST |
| REQ-014 | PR Gates and Merge Orchestration | TRD-017 | TRD-017-TEST |
| REQ-015 | Inbox and Agent Mail | TRD-018 | TRD-018-TEST |
| REQ-016 | Sentinel and External Monitors | TRD-019 | TRD-019-TEST |
| REQ-017 | Logs, Reports, and Debug | TRD-020 | TRD-020-TEST |
| REQ-018 | Attach and Interactive Recovery | TRD-021 | TRD-021-TEST |
| REQ-019 | Plan/PRD/TRD Support | TRD-022 | TRD-022-TEST |
| REQ-020 | Migration and Coexistence | TRD-023 | TRD-023-TEST |
| REQ-021 | Testing and Deterministic Simulation | TRD-014 | TRD-014-TEST |
| REQ-022 | Observability and Operations | TRD-024 | TRD-024-TEST |
| REQ-023 | Security and Isolation | TRD-005, TRD-025 | TRD-005-TEST, TRD-025-TEST |
| REQ-024 | Documentation and Operator Education | TRD-026 | TRD-026-TEST |
| REQ-025 | Comparative Architecture Spike | TRD-001 | TRD-001-TEST |

## 8.1 AC-Level Coverage Notes

The matrix above is requirement-level. Detailed AC coverage is carried by each task's `Validates PRD ACs:` field and paired `TRD-NNN-TEST` task. Implementation policy:

- Each implementation task must preserve its listed PRD AC IDs when split or moved.
- Each paired test task must verify all AC IDs listed by its implementation task unless the test task explicitly delegates coverage to another named test task.
- Protocol-heavy ACs must assert request/response envelope, emitted event type, projection update, and failure behavior.
- Recovery ACs must assert observation-before-resolution event ordering and no destructive replay without idempotency keys.

## 8.2 Concrete AC-to-Task Coverage

| AC ID | Covered By | Verification Focus |
|-------|------------|--------------------|
| AC-001-1 | TRD-002; TRD-002-TEST | Given the server is started, when it initializes, then it loads configured projects from durable storage and starts supervision trees for active projects. |
| AC-001-2 | TRD-002; TRD-002-TEST | Given the server receives a command from the Node CLI, when validation succeeds, then it records the command outcome as durable events. |
| AC-001-3 | TRD-002; TRD-002-TEST | Given the server crashes and restarts, when it boots, then it rebuilds in-memory actors from durable events/projections. |
| AC-002-1 | TRD-003; TRD-003-TEST | Given any task/run/phase transition, when the transition occurs, then a domain event is appended before projections are updated. |
| AC-002-2 | TRD-003; TRD-003-TEST | Given an event is appended, when projections are rebuilt from scratch, then task/run status matches current production projection state. |
| AC-002-3 | TRD-003; TRD-003-TEST | Given an event schema changes, when migrations run, then old events remain readable through versioned decoders. |
| AC-003-1 | TRD-004; TRD-004-TEST | Given a task is created or updated, when its events are projected, then `foreman task show/list` renders from the task projection. |
| AC-003-2 | TRD-004; TRD-004-TEST | Given a run emits phase/worker events, when `foreman status` is called, then the run projection displays active, in-progress, failed, blocked, and completed counts without log inference. |
| AC-003-3 | TRD-004; TRD-004-TEST | Given projection corruption or drift is detected, when a rebuild is requested, then projections can be dropped and rebuilt from events. |
| AC-004-1 | TRD-005, TRD-006; TRD-005-TEST, TRD-006-TEST | Given the server is running, when a user runs `foreman task create`, `foreman run`, `foreman status`, or `foreman logs`, then the CLI calls the server API rather than mutating DB state directly. |
| AC-004-2 | TRD-005, TRD-006; TRD-005-TEST, TRD-006-TEST | Given legacy aliases such as `--bead`, `dashboard`, or deprecated command names are used, when compatibility mode is enabled, then the CLI warns and maps to the new command. |
| AC-004-3 | TRD-005, TRD-006; TRD-005-TEST, TRD-006-TEST | Given the server is not running, when a command requires it, then the CLI auto-starts the local server by default or prints a clear `foreman server start` instruction if auto-start fails or is disabled. |
| AC-005-1 | TRD-006, TRD-007; TRD-006-TEST, TRD-007-TEST | Given a user runs a legacy command, when an equivalent new command exists, then the CLI prints the new spelling. |
| AC-005-2 | TRD-006, TRD-007; TRD-006-TEST, TRD-007-TEST | Given documentation is generated, when CLI reference is built, then deprecated aliases are clearly marked. |
| AC-005-3 | TRD-006, TRD-007; TRD-006-TEST, TRD-007-TEST | Given a new user follows `foreman --help`, when they scan commands, then lifecycle verbs are grouped by domain. |
| AC-006-1 | TRD-011; TRD-011-TEST | Given Elixir starts a phase requiring model execution, when the selected adapter is `pi_sdk`, then it starts or reuses a Node worker that calls `createAgentSession()`. |
| AC-006-2 | TRD-011; TRD-011-TEST | Given the worker receives tool calls, when tools complete, then structured tool events stream back to Elixir. |
| AC-006-3 | TRD-011; TRD-011-TEST | Given the worker exits unexpectedly, when Elixir observes missing heartbeat or process exit, then the run is marked recoverable and recovery policy starts. |
| AC-006-4 | TRD-011; TRD-011-TEST | Given current workflow prompts/tools are used, when executed through the bridge, then existing artifacts and reports are produced with equivalent semantics. |
| AC-007-1 | TRD-012; TRD-012-TEST | Given a workflow specifies a model/provider, when execution starts, then provider selection is resolved through an adapter registry. |
| AC-007-2 | TRD-012; TRD-012-TEST | Given Pi SDK is unavailable in v1, when execution is requested without a production-ready adapter, then Foreman fails before execution with a clear message that Pi SDK is the only required production adapter for v1. |
| AC-007-3 | TRD-012; TRD-012-TEST | Given a provider lacks Pi-specific tool semantics, when a workflow uses unsupported tools, then Foreman fails before execution with actionable validation. |
| AC-008-1 | TRD-009; TRD-009-TEST | Given a workflow is loaded, when a run starts, then the run state machine records phase order and current phase. |
| AC-008-2 | TRD-009; TRD-009-TEST | Given a phase passes, fails, retries, or times out, when the event is recorded, then next transition is deterministic and testable. |
| AC-008-3 | TRD-009; TRD-009-TEST | Given a retry loop such as QA ⇄ developer or PR-review ⇄ developer, when retry limits are reached, then failure state includes retry history. |
| AC-009-1 | TRD-013; TRD-013-TEST | Given an existing YAML workflow, when migrated or loaded, then phase order, model selection, retry rules, artifacts, mail hooks, and builtins are preserved. |
| AC-009-2 | TRD-013; TRD-013-TEST | Given an epic workflow, when PRD/TRD/implementation phases run, then planning artifacts remain accessible under docs/reports or configured report paths. |
| AC-009-3 | TRD-013; TRD-013-TEST | Given a bash or builtin phase exists, when executed by Elixir, then command output and exit status are converted to phase events. |
| AC-010-1 | TRD-008; TRD-008-TEST | Given a project is registered, when listed or shown, then the projection includes path, status, default branch, config, and health. |
| AC-010-2 | TRD-008; TRD-008-TEST | Given a task is created, approved, blocked, closed, or annotated, when the command succeeds, then event and projection state update atomically. |
| AC-010-3 | TRD-008; TRD-008-TEST | Given dependencies exist, when dispatchable tasks are queried, then blocked ready tasks are excluded until blockers close. |
| AC-011-1 | TRD-010; TRD-010-TEST | Given ready tasks exist and capacity is available, when scheduler ticks, then eligible tasks are claimed and run actors are started. |
| AC-011-2 | TRD-010; TRD-010-TEST | Given capacity is exhausted, when more tasks are ready, then tasks remain ready and a projection records skipped/capacity reason. |
| AC-011-3 | TRD-010; TRD-010-TEST | Given project-level concurrency limits exist, when dispatching, then limits are enforced across CLI, daemon, and integrations. |
| AC-012-1 | TRD-015; TRD-015-TEST | Given Elixir restarts while a Node/Pi worker is still running, when heartbeat/session metadata is recoverable, then Elixir reattaches and emits `WorkerReattached`. |
| AC-012-2 | TRD-015; TRD-015-TEST | Given the worker cannot be reattached, when restart policy allows, then Elixir restarts the phase from the last safe checkpoint and emits `WorkerRestarted`. |
| AC-012-3 | TRD-015; TRD-015-TEST | Given projections disagree with external state such as OS processes, worktrees, git branches, or GitHub PRs, when reconciliation runs, then observed differences are recorded as events and resolved by policy. |
| AC-013-1 | TRD-016; TRD-016-TEST | Given a run starts, when worktree creation succeeds, then the worktree path and branch/revision are recorded as events. |
| AC-013-2 | TRD-016; TRD-016-TEST | Given a stale worktree exists, when a new run starts, then Foreman follows configured reuse/clean/rebase policy. |
| AC-013-3 | TRD-016; TRD-016-TEST | Given Git or Jujutsu backend is selected, when VCS operations execute, then backend-specific details remain behind a VCS adapter. |
| AC-014-1 | TRD-017; TRD-017-TEST | Given a PR is created, when GitHub checks and review data are delayed, then readiness projections include pending/seen/stable states rather than false-ready. |
| AC-014-2 | TRD-017; TRD-017-TEST | Given a PR reaches stable ready state, when merge phase starts, then merge gate revalidates readiness before merging. |
| AC-014-3 | TRD-017; TRD-017-TEST | Given merge fails, when `foreman run show` or debug is used, then failure reason is visible from events and reports. |
| AC-015-1 | TRD-018; TRD-018-TEST | Given a phase starts/completes/fails, when mail hooks are configured, then messages are appended as events and projected to inbox. |
| AC-015-2 | TRD-018; TRD-018-TEST | Given an operator sends a message to an active run, when the worker supports receiving it, then delivery status is tracked. |
| AC-015-3 | TRD-018; TRD-018-TEST | Given `foreman inbox --watch` is used, when new messages arrive, then updates stream without polling full history. |
| AC-016-1 | TRD-019; TRD-019-TEST | Given sentinel detects repeated test failure, when threshold is reached, then a bug task is created/updated through Elixir commands. |
| AC-016-2 | TRD-019; TRD-019-TEST | Given Jira/GitHub integrations detect external transitions, when configured, then tasks are created with external links and dedupe keys. |
| AC-016-3 | TRD-019; TRD-019-TEST | Given integration input is duplicated, when processed, then idempotency prevents duplicate tasks/runs. |
| AC-017-1 | TRD-020; TRD-020-TEST | Given a worker emits stdout/stderr/tool/assistant events, when stored, then `foreman logs` can render compact or raw views. |
| AC-017-2 | TRD-020; TRD-020-TEST | Given phase artifacts are written, when debug is invoked, then debug references both event timeline and artifact files. |
| AC-017-3 | TRD-020; TRD-020-TEST | Given logs are purged, when events remain, then historical status/debug summaries are still possible. |
| AC-018-1 | TRD-021; TRD-021-TEST | Given a Pi SDK worker exposes an attach/session identifier, when `foreman run attach` is called, then the CLI opens an interactive or streaming attach mode. |
| AC-018-2 | TRD-021; TRD-021-TEST | Given attach is unsupported for a provider, when requested, then Foreman prints the reason and alternative logs/control commands. |
| AC-018-3 | TRD-021; TRD-021-TEST | Given a human interrupts a phase, when resume is requested, then the run records the interruption and next action. |
| AC-019-1 | TRD-022; TRD-022-TEST | Given a user requests PRD/TRD planning, when `foreman plan prd|trd` runs, then planning phases execute through the same worker adapter/event pipeline. |
| AC-019-2 | TRD-022; TRD-022-TEST | Given planning artifacts are created, when tasks are generated, then traceability links are stored as events/projections. |
| AC-019-3 | TRD-022; TRD-022-TEST | Given existing `/ensemble:create-prd` or `/skill:ensemble-create-prd` flows are used, when compatibility mode is enabled, then they remain available. |
| AC-020-1 | TRD-023; TRD-023-TEST | Given an existing Foreman project, when migration runs, then projects, tasks, runs, workflows, inbox messages, and config are imported or mapped. |
| AC-020-2 | TRD-023; TRD-023-TEST | Given TS-era runs exist, when viewed after migration, then their historical records remain readable. |
| AC-020-3 | TRD-023; TRD-023-TEST | Given migration has not completed, when compatibility mode is enabled, then `run`, `status`, `watch`, `reset`, `retry`, `stop`, `merge`, `pr`, `attach`, `inbox`, `task`, `plan`, `sling`, and `doctor` can delegate to legacy TS code. |
| AC-021-1 | TRD-014; TRD-014-TEST | Given a run state machine, when tested, then phase transitions can be simulated in-memory with event assertions. |
| AC-021-2 | TRD-014; TRD-014-TEST | Given worker failures are simulated, when recovery tests run, then expected recovery events are emitted deterministically. |
| AC-021-3 | TRD-014; TRD-014-TEST | Given CLI integration tests run, when server readiness is required, then tests use supervised test server APIs instead of arbitrary subprocess sleeps. |
| AC-022-1 | TRD-024; TRD-024-TEST | Given `foreman server doctor` runs, when the server is healthy, then it validates DB, projections, workers, VCS, provider adapters, and integrations. |
| AC-022-2 | TRD-024; TRD-024-TEST | Given metrics are enabled, when runs progress, then counters/timers are emitted for phase duration, retries, failures, recoveries, worker restarts, and projection lag. |
| AC-022-3 | TRD-024; TRD-024-TEST | Given a status anomaly occurs, when debug is invoked, then event timeline identifies the first inconsistent transition. |
| AC-023-1 | TRD-005, TRD-025; TRD-005-TEST, TRD-025-TEST | Given worker processes start, when environment is prepared, then secrets are scoped to the project/run and forbidden variables are stripped. |
| AC-023-2 | TRD-005, TRD-025; TRD-005-TEST, TRD-025-TEST | Given server API is exposed beyond local socket, when authentication is configured, then commands require an auth token or equivalent. |
| AC-023-3 | TRD-005, TRD-025; TRD-005-TEST, TRD-025-TEST | Given destructive commands are requested, when executed, then authorization and audit events are recorded. |
| AC-024-1 | TRD-026; TRD-026-TEST | Given the migration ships, when users read the docs, then README, User Guide, CLI Reference, and architecture docs describe Elixir server + Node CLI + Node worker responsibilities. |
| AC-024-2 | TRD-026; TRD-026-TEST | Given commands are renamed or deprecated, when users run old commands, then docs and CLI warnings point to replacements. |
| AC-024-3 | TRD-026; TRD-026-TEST | Given operators need to troubleshoot, when they read docs, then event/projection/recovery concepts are explained with examples. |
| AC-025-1 | TRD-001; TRD-001-TEST | Given the spike starts, when prototypes are built, then Elixir/OTP and WolverineFx/Marten each implement the same minimal lifecycle: create task → approve task → dispatch simulated worker → stream status → complete run → rebuild read model. |
| AC-025-2 | TRD-001; TRD-001-TEST | Given a simulated worker crashes mid-phase, when recovery runs, then each prototype demonstrates its attach/restart strategy and records the operator-visible recovery timeline. |
| AC-025-3 | TRD-001; TRD-001-TEST | Given the prototypes are evaluated, when the spike report is written, then it compares runtime supervision, durable messaging/CQRS, event/projection rebuild, local developer setup, Node CLI integration, Node/Pi worker boundary, observability, testing complexity, and migration risk. |
| AC-025-4 | TRD-001; TRD-001-TEST | Given WolverineFx's durable inbox/outbox, saga persistence, scheduled message handling, dead-letter support, and Marten/Postgres event-store fit are evaluated, when the recommendation is made, then the report explicitly explains whether those benefits outweigh OTP supervision for Foreman's local long-running worker/process model. |

## 9. Adversarial Review

### 9.1 Architecture Issues

1. **Issue:** Full OTP ownership can create a large cutover surface before value is visible.  
   **Resolution:** Keep PR boundaries vertical and user-observable; do not merge a PR that only introduces private scaffolding without a command/operator behavior.

2. **Issue:** Node worker protocol and Elixir state machines may disagree about phase lifecycle semantics.  
   **Resolution:** Version the worker protocol, contract-test every phase event, and make Elixir reject unknown or out-of-order worker events.

3. **Issue:** Remote server access increases security requirements beyond current local-only workflows.  
   **Resolution:** Require explicit remote enablement, authenticated HTTP, audit events, and secret redaction before remote binding is allowed.

### 9.2 Coverage Issues

1. **Issue:** REQ-025 requires a spike before backend commitment.  
   **Resolution:** TRD-001 completed the spike in `docs/spikes/TRD-2026-014-architecture-spike.md` and confirmed Elixir/OTP remains selected.

2. **Issue:** Documentation is easy to defer until after behavior changes.  
   **Resolution:** TRD-026 is in the final shippable PR and explicitly covers README, User Guide, CLI Reference, and architecture docs.

### 9.3 Dependency and Estimate Issues

1. **Issue:** Recovery, VCS, and PR gates depend on worker protocol and state machine correctness, creating a deep chain.  
   **Resolution:** Keep deterministic simulation harness in PR 3 and use it as the verification layer before external recovery behavior lands.

### 9.4 Testability Issues

1. **Issue:** “Equivalent semantics” for workflow parity can be vague.  
   **Resolution:** TRD-013-TEST must use fixture workflows with expected artifacts, phase events, retry histories, and report paths.

2. **Issue:** External systems such as GitHub and OS processes can produce flaky tests.  
   **Resolution:** Use adapter fakes for deterministic tests and reserve live integration coverage for smoke suites with explicit timeouts.

## 10. Design Readiness Gate

| Dimension | Score | Notes |
|-----------|-------|-------|
| Architecture completeness | 4.75 | Components, transports, data flows, contracts, NFRs, fixture schemas, external boundaries, and final stack decision are defined; REQ-025 spike is complete |
| Task coverage | 4.75 | Every PRD requirement and AC has implementation/test coverage mapping |
| Dependency clarity | 4.75 | Dependencies are explicit and acyclic; additional recovery, integration, attach, and planning tracks can run in parallel |
| Estimate confidence | 4.75 | Tasks remain below 8h with concrete fixtures, contracts, and verification targets |
| **Overall** | **4.75** | **PASS** |

Design gate decision: PASS. Design Readiness: 4.50 -> 4.75 (improved). TRD-001 spike results are complete; proceed with Elixir/OTP implementation tasks.

## 11. Traceability Validation Summary

Traceability check: 25 requirements covered, 0 uncovered, 0 orphaned annotations.

## 12. Next Steps

1. Review and approve this TRD.
2. Run `/ensemble:configure-team docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` to auto-configure the team.
3. Run `/ensemble:implement-trd-beads docs/TRD/TRD-2026-014-elixir-backend-orchestration.md` only after approval.

## 13. Revision History

| Date | Version | Author | Changes |
|------|---------|--------|---------|
| 2026-06-16 | 1.0.0 | Pi Agent | Initial TRD from PRD-2026-014 |
| 2026-06-16 | 1.0.1 | Pi Agent | Clarified conditional architecture gate, API/event/worker contracts, recovery rules, dependency parallelization, team config, test specificity, and AC-level coverage notes |
| 2026-06-16 | 1.0.2 | Pi Agent | Added fixture schemas, integration and VCS/PR contracts, quality requirements, concrete AC-to-task coverage, refined team metrics, and further dependency parallelization |
| 2026-06-16 | 1.0.3 | Pi Agent | Converted Master Task List to parser-compatible checkbox task format for implement-trd-beads |
| 2026-06-16 | 1.0.4 | Pi Agent | Converted Team Configuration to implement-trd-beads role-list schema and added local agent registry entries |
| 2026-06-16 | 1.0.5 | Pi Agent | Recorded TRD-001 comparative architecture spike result and confirmed Elixir/OTP target architecture |
