---
document_id: PRD-2026-7b4a3944
version: 1.0.1
status: Draft
date: 2026-07-29
scale_depth: DEEP
total_requirements: 23
readiness_score: 4.0
---

# PRD: Go/Elixir CQRS Slice — Functional Parity Gaps

## PRD Health Summary

| Priority | Count |
|---|---|
| Must | 14 |
| Should | 8 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---|
| AC coverage | 23/23 (100%) |
| Risk flags | 10 |
| Dependency rows | 17 |
| Ambiguity markers | 15 |
| Open ambiguity | 0 |
| Readiness score | 4.0 — PASS |
| Version | 1.0.1 |

### Changelog
| Version | Date | Changes |
|---|---|---|
| 1.0.0 | 2026-07-29 | Initial draft |
| 1.0.1 | 2026-07-29 | Resolved 15/15 ambiguity markers: heartbeat timeout 60s, crash loop 3×/5min, config propagation next launch, attach-bridge adapter policy, PR polling fallback 5min, PR gate active block, scheduler crash re-dispatch, stuck-run 15min, VCS retry 3× exp backoff, gap-closure taxonomy, run cap 100/project, secrets management, workflow template bundled+fallback, ProjectRegistry dedicated module, LiveView required. Readiness gate: 3.25 → 4.0 PASS. |

---

## 1. Executive Summary

**What the branch built (vs `main`):** 129 files, including 84 typed domain event structs, 11 typed command structs, 14 Phoenix controllers, 5 projection handlers, supervised aggregate actor infrastructure, workflow components, inbox/poller, recovery, webhooks, and architecture tests. **What the branch does not yet have:** 28 absent modules, 35 absent tests, and several absent environment/automation configs. All are identified by name and responsibility in §3.

**What this PRD does:** defines requirements for closing the functional parity gaps between the Go/Elixir CQRS slice and the Go-only baseline, preserving the EventStore/CommandRouter/Phoenix/aggregate actor commitments from the existing architecture. It is scoped to functional parity only; performance, scaling, and UX are out of scope unless explicitly named.

## 2. Background and Evidence

**What the branch added (vs `main`):**
- 84 typed domain event structs in `foreman_server/events/`
- 11 typed command structs in `foreman_server/commands/`
- 14 Phoenix HTTP controllers and routes in `foreman_server_web/`
- 5 projection handlers (phase, project, run, task, worker)
- Supervised aggregate actor infrastructure (`aggregate/actor.ex`, `aggregate/supervisor.ex`)
- Workflow components (interpreter, prompt_resolver, prompt_artifact_store, resolver)
- `inbox/poller.ex` + `inbox_dedupe.ex` as successor to `inbox.ex`
- `recovery.ex` as successor to `recovery_engine.ex`
- `webhooks/github.ex` and `pr_associate.ex`
- Architecture tests (`event_typing_test.exs`, `event_store_enforcement_test.exs`)

**What remains absent (from gap analysis §2a, 28 files):**
- Worker runtime: `worker_launcher.ex`, `worker_protocol.ex`, `worker_environment.ex`, `runtime_safety.ex`, `security.ex`
- Run/phase state machines: `run_actor.ex`, `phase_actor.ex`, `board_item_state_machine.ex`
- Domain coordinators: `planning_flow.ex`, `recovery_engine.ex`, `operations.ex`
- Project infrastructure: `project_registry.ex`, `project_store.ex`, `project_supervisor.ex`, `project.ex`
- PR lifecycle: `pr_gate.ex`, `pr_monitor.ex`
- Ingestion: `attach_bridge.ex`, `migration_importer.ex`, `integration_ingestion.ex`
- Persistence: `projection_store/postgres.ex`
- VCS: `vcs_adapter.ex`
- Infrastructure: `aggregate_router.ex`, `runtime_info.ex`, `provider_registry.ex`
- Debug: `debug_views.ex`, `simulation_harness.ex`
- Config: `config/dev.exs`, `config/prod.exs`, `config/test.exs`
- Workflow templates: 6 YAML templates in `priv/defaults/workflows/`
- Tests: 35 test files absent (see gap analysis §5)

**Architectural constraints (preserved from slice):**
- `CommandRouter` is the sole append point — no direct `append_to_stream` outside `CommandRouter`
- All mutations route through Phoenix HTTP → `CommandRouter.dispatch/1`
- Aggregate actors are supervised, rehydrated via `Aggregate.load/2`
- State lives in the event log; projections are read models
- Typed event structs with `@enforce_keys`, `@type t`, `@derive Jason.Encoder`

**Elicitation decisions:**
- Worker runtime: fresh rewrite using `aggregate/actor.ex` + `CommandRouter` (not port from `main`)
- Ingestion paths: consolidate attach bridge + integration ingestion + migration importer into existing inbox/poller framework
- Run/phase lifecycle: complete state-machine aggregate using `%State{}` pattern
- Scope: all 28 absent files must be addressed (no deferral)
- Crash mid-run: projection update + continue
- Duplicate/invalid command transitions: emit domain event (e.g. `RunAlreadyCompleted`)
- Silent event loss: Postgres data checksums + WAL validation / replay audit
- Project access revoked: pause active runs, surface `ProjectAccessRevoked` event, require operator to close or transfer
- Scale threshold: hard limit per aggregate stream, cap concurrent active runs per project at 100, reject new runs with clear error
- Gap-closure approach: subsystem-by-subsystem. Rewrite modules that are tightly coupled to existing actors/state machines (`overwatch.ex`, `board_item_state_machine.ex`, `simulation_harness.ex`, `recovery.ex`, `pr_monitor.ex`, `pr_gate.ex`). Port pure adapters and helpers where behavior remains valid (`runtime_info.ex`, `provider_registry.ex`, `vcs_adapter.ex`, `attach_bridge.ex`, `migration_importer.ex`, `integration_ingestion.ex`, `aggregate_router.ex`). Green-field write for genuinely new capability (`project_registry.ex`, `project_store.ex`, `planning_flow.ex`).

---

## 3. Requirements

### 3a. Worker Runtime

### REQ-001: Must | High | ⚠️ Risk: zombie worker cleanup; crash loop detection
The backend MUST implement a worker runtime using `aggregate/actor.ex` + `CommandRouter` — a fresh rewrite, not a port of `main`'s `worker_launcher.ex`, `worker_protocol.ex`, or `worker_environment.ex`.

- AC-001-1: Given a run is active, when a worker is launched, then `Overwatch` tracks the worker lifecycle and emits `WorkerHeartbeat` or `WorkerExited` events through `CommandRouter`
- AC-001-2: Given a worker process exits, when `Overwatch` detects the exit, then the run projection is updated with the exit/failure state
- AC-001-3: Given a worker command, when it is dispatched, then it routes through the aggregate command path — not direct event writes
- AC-001-4: Given a worker crashes and restarts, when the restarted worker reconnects, then no duplicate work occurs and the run state reflects the current aggregate version
- AC-001-5: Given a worker becomes unresponsive (no heartbeat for 60 seconds), when the timeout elapses, then the run is marked `WorkerUnresponsive` and recovery is triggered

### REQ-002: Must | Medium | ⚠️ Risk: crash loop may exhaust aggregate actor mailbox
The worker runtime MUST implement crash loop detection and worker zombie cleanup.

- AC-002-1: Given a worker restarts more than 3 times within a 5-minute window, when the threshold is exceeded, then the worker is marked `WorkerCrashed` and the run is paused with a clear error
- AC-002-2: Given a worker process is orphaned (parent node goes away), when `Overwatch` detects the orphan, then the worker is cleaned up and its slot is released

### REQ-003: Should | Medium | Worker environment config isolation
Each worker MUST receive an isolated environment configuration.

- AC-003-1: Given a worker is launched, when it starts, then it receives a complete environment map sourced from the project's registered configuration — no environment leakage between workers
- AC-003-2: Given a worker's environment config changes while it is running, when the worker is restarted or a new worker is launched for the same run, then the new config values take effect. Config changes do not apply mid-run without a worker restart.

---

### 3b. Run/Phase State-machine Aggregates

### REQ-004: Must | High | ⚠️ Risk: incomplete state transitions leave runs in limbo
The backend MUST implement complete state-machine aggregates for Run and Phase, using the `%State{}` struct pattern with `%State{state | ...}` updates.

- AC-004-1: Given a `RunStarted` event, when the run aggregate is created, then its initial state is `{:active, run_id: _, status: "started", terminal?: false}`
- AC-004-2: Given a run is active, when `CompleteRun` is dispatched and the run is not already terminal, then a `RunCompleted` event is appended and the run transitions to terminal
- AC-004-3: Given a run is active, when `CompleteRun` is dispatched and the run is already terminal (completed, failed, or cancelled), then a `RunAlreadyCompleted` domain event is emitted and the state is unchanged — the command is idempotent [RISK: if this is not implemented, duplicate completes cause state corruption]
- AC-004-4: Given a run aggregate restarts after server crash, when `Aggregate.load/2` is called, then the full event stream is replayed via `apply_event` and the correct terminal or non-terminal state is restored

### REQ-005: Must | High | ⚠️ Risk: aggregate actor crash leaves stream at wrong version
Phase aggregates MUST follow the same `%State{}` struct pattern and implement optimistic concurrency.

- AC-005-1: Given a phase is active, when `StartPhase` is dispatched, then `PhaseStarted` is appended and the phase state transitions to active
- AC-005-2: Given a phase is active, when `CompletePhase` is dispatched, then `PhaseCompleted` is appended and the phase state transitions to terminal
- AC-005-3: Given two `CompletePhase` commands race for the same phase stream, when the second append uses the wrong expected stream version, then the append fails with a concurrency conflict and the actor retries with the correct version

### REQ-006: Must | Medium | Board item state machine
The backend MUST implement board item status state transitions.

- AC-006-1: Given a board item, when a status transition command is dispatched, then the `BoardItemStateMachine` aggregate applies the transition and emits the corresponding event
- AC-006-2: Given an invalid status transition (e.g., `closed` → `in_progress`), when the command is dispatched, then it is rejected with an `:invalid_transition` error

---

### 3c. Unified Ingestion

### REQ-007: Must | High | ⚠️ Risk: consolidation may break existing attach-bridge or migration importers if they have specialized behavior not captured in the inbox/poller model
The backend MUST consolidate `attach_bridge.ex`, `integration_ingestion.ex`, and `migration_importer.ex` into the existing `inbox/poller` framework.

- AC-007-1: Given an attach-bridge webhook arrives, when it is received, then an adapter normalizes the attach-bridge payload into an `InboxItem`, which is then routed through `Inbox.Poller` with deduplication applied. Specialized attach-bridge behavior (e.g., streaming metadata, connection lifecycle) is preserved in the adapter layer before normalization.
- AC-007-2: Given an integration ingestion webhook arrives, when it is received, then it is routed through `Inbox.Poller` and deduplicated by correlation ID
- AC-007-3: Given a migration import is dispatched, when it is processed, then it routes through `CommandRouter` and appends migration events to the event store
- AC-007-4: Given a duplicate ingestion event arrives, when `inbox_dedupe.ex` checks the dedupe window, then the duplicate is rejected and delivery status is tracked

### REQ-008: Should | Medium | External trigger webhook ingestion
External triggers MUST be receivable via webhook-first push, with pull fallback for systems that cannot push.

- AC-008-1: Given an external trigger webhook arrives, when it is received, then it is routed to the appropriate handler and delivery status is tracked
- AC-008-2: Given an external system cannot push webhooks, when a pull-based inbox poll is configured, then the poller periodically fetches and ingests pending triggers

---

### 3d. PR Lifecycle

### REQ-009: Must | High | ⚠️ Risk: GitHub API rate limits; PR state sync lag
The backend MUST support PR association and GitHub webhook-driven state sync.

- AC-009-1: Given a run completes, when the operator provides a PR URL or identity, then `pr_associate.ex` stores the association and emits `PrAssociated` through `CommandRouter`
- AC-009-2: Given a PR is associated with a run, when GitHub sends a webhook indicating state change (opened, merged, closed, conflicted), then `webhooks/github.ex` processes it and the run projection reflects the new PR state
- AC-009-3: Given a PR is associated with a run, when GitHub sends a webhook indicating state change (opened, merged, closed, conflicted), then `webhooks/github.ex` processes it and the run projection reflects the new PR state. If webhooks are missed or reordered, a periodic polling fallback reconciles PR state every 5 minutes.

### REQ-010: Should | Medium | PR gate enforcement
The backend MUST enforce PR status gates before allowing runs to proceed to merge.

- AC-010-1: Given a run is pending merge, when the PR status is not `open` and not `merged`, then the run is blocked and a clear status is surfaced
- AC-010-2: Given a run is pending merge, when the PR status is not `open` and not `merged`, then the PR gate actively blocks run progression — the run does not advance to merge until the PR status becomes acceptable.

---

### 3e. Recovery and Scheduler

### REQ-011: Must | High | ⚠️ Risk: scheduler may miss fires during outage; double-dispatch on restart
The backend MUST implement a recovery scanner and fire-and-track scheduler using the existing `recovery.ex` pattern.

- AC-011-1: Given the server restarts, when `Recovery` GenServer starts, then it scans `ProjectionStore` for interrupted runs and emits recovery events with explicit outcomes: `RunDetected`, `RunResumed`, or `RunResolved`
- AC-011-2: Given recovery emits events, when the run resumes, then no duplicate processing occurs — idempotency is preserved via aggregate version and command deduplication
- AC-011-3: Given the scheduler runtime is active, when a scheduled fire is due, then the scheduler records intent (`ScheduledFireRecorded`) and the worker confirms execution on pickup (`ScheduledFireConfirmed`) — fire-and-track pattern
- AC-011-4: Given a server restart occurs while a scheduled fire is pending (intent recorded but worker pickup unconfirmed), when recovery runs, then recovery re-dispatches the fire to a new worker — no fire is lost and the run continues.

### REQ-012: Should | Medium | Stuck-run detection
The recovery scanner MUST detect and surface runs that are stuck (no progress despite being active).

- AC-012-1: Given a run is active, when no phase or worker events have been appended for 15 minutes, then the run is flagged `Stuck` in the projection and an alert is surfaced.

---

### 3f. VCS Adapter

### REQ-013: Must | High | ⚠️ Risk: VCS abstraction may not cover all GitHub Enterprise scenarios
The backend MUST implement a VCS adapter abstraction layer.

- AC-013-1: Given a VCS operation is required (clone, branch, PR creation), when the operation is dispatched, then it routes through the VCS adapter abstraction — not direct GitHub API calls scattered through domain code
- AC-013-2: Given `vcs_adapter.ex` is absent, when a VCS operation fails transiently, then it retries up to 3 times with exponential backoff. Non-transient failures (e.g., auth rejection, not found) are not retried.
- AC-013-3: Given `vcs_adapter.ex` is absent, when it is implemented, then it emits `VcsOperationStarted`, `VcsOperationCompleted`, or `VcsOperationFailed` events through `CommandRouter`

---

### 3g. Configuration Parity

### REQ-014: Must | Medium | Environment configuration files
The backend MUST restore environment-specific configuration files.

- AC-014-1: Given `config/dev.exs` is absent, when the application starts in dev mode, then all required runtime configuration (EventStore, ProjectionStore, Phoenix endpoint, Overwatch) is present and loadable
- AC-014-2: Given `config/test.exs` is absent, when tests run, then the test environment uses an appropriate test adapter (e.g., memory EventStore) and test-specific configuration
- AC-014-3: Given `config/prod.exs` is absent, when the application starts in prod mode, then production configuration is loadable from environment variables. Secrets (API keys, database credentials) are sourced from a secrets manager (Vault, AWS Secrets Manager, or equivalent) in prod; from environment variables in dev and test.

---

### 3h. Workflow Template Parity

### REQ-015: Should | Medium | Workflow YAML templates
The backend MUST restore the 6 workflow YAML templates in `priv/defaults/workflows/`.

- AC-015-1: Given `priv/defaults/workflows/` is absent, when `foreman init` runs, then the 6 standard workflow templates are installed. Templates are bundled with the application; if the bundled copy is unavailable, a fallback download from a remote source is attempted.
- AC-015-2: Given a workflow template is missing a required phase, when the interpreter loads it, then it fails fast with a clear error

---

### 3i. Project Registry, Store, and Supervisor

### REQ-016: Must | High | ⚠️ Risk: project operations without a registry may race
The backend MUST implement project process registry, persistence layer, and OTP supervisor.

- AC-016-1: Given a project is registered, when it is started, then `ProjectSupervisor` starts and supervises the project process tree
- AC-016-2: Given a dedicated `ProjectRegistry` is implemented, when a project process registers or unregisters, then `ProjectRegistry` maintains the canonical name-to-pid mapping. `ProjectSupervisor` monitors and restarts crashed project processes using this mapping — `Aggregator.supervisor` alone is insufficient for this role.
- AC-016-3: Given `project_store.ex` is absent, when project configuration is persisted, then it is stored via the event store (append-only) and projected through `ProjectionStore` — not a separate persistence mechanism

### REQ-017: Should | Low | Planning flow coordinator
The backend MUST support planning commands already modeled by the domain.

- AC-017-1: Given `plan.prd` or `plan.trd` commands are dispatched, when they are processed, then they route through the backend and `PlanningFlowStarted` events are appended
- AC-017-2: Given `planning_flow.ex` is absent, when a planning flow is active, then trace events are appended through the existing aggregate infrastructure

---

### 3j. Debug Views and Operations Helpers

### REQ-018: Should | Low | LiveView debug pages
The backend SHOULD restore LiveView debug pages for development diagnostics.

- AC-018-1: Given `debug_views.ex` is absent, when the application runs in dev mode, then LiveView is required to provide real-time, interactive debug pages for run/phase/worker state diagnostics.

### REQ-019: Should | Low | Operations helpers
The backend SHOULD implement operations helper functions.

- AC-019-1: Given `operations.ex` is absent, when an operator needs to inspect or manipulate run state manually, then equivalent operations helpers are available through `CommandRouter`-backed commands — not direct state manipulation

---

### 3k. Test Suite Parity

### REQ-020: Must | High | ⚠️ Risk: absent tests mean regressions go undetected
The backend MUST restore test coverage for all absent domain modules.

- AC-020-1: Given `aggregate_router_test.exs` is absent, when command routing is tested, then equivalent coverage exists for the `CommandRouter` dispatch path
- AC-020-2: Given `overwatch_test.exs` is absent, when worker lifecycle is tested, then equivalent coverage exists for `Overwatch` → aggregate → event append path
- AC-020-3: Given `recovery_engine_test.exs` is absent, when recovery behavior is tested, then equivalent coverage exists for `recovery.ex` scanner behavior
- AC-020-4: Given 35 test files are absent (see gap analysis §5), when each absent domain module is implemented, then a corresponding test file is created covering the module's core behavior
- AC-020-5: Given all domain modules are implemented, when the full test suite runs, then aggregate AC1 (supervised actor) and AC2 (idempotency) tests remain green

---

### 3l. Non-Functional Requirements

### REQ-021: Must | High | Event store durability and gap detection
The event store MUST use Postgres with data checksums enabled and WAL validation to detect silent data loss.

- AC-021-1: Given Postgres is configured, when the database is initialized, then `data_checksums = on` and `wal_level = replica` (or `logical`) are enabled
- AC-021-2: Given `recovery.ex` runs, when it detects a mismatch between projected event count and expected event count, then it surfaces a `StreamGapDetected` event and triggers an audit
- AC-021-3: Given silent data loss occurs, when the gap is detected, then the system alerts operators and prevents further appends to the affected stream until the gap is resolved

### REQ-022: Must | High | Scale limit enforcement
The backend MUST enforce a hard limit on concurrent active runs per project.

- AC-022-1: Given a project has reached its concurrent run limit (100 active runs per project), when a new `StartRun` command is dispatched, then it is rejected with a `:run_limit_exceeded` error
- AC-022-2: Given the run limit is enforced at the aggregate level, when the aggregate receives `StartRun` and the count is at limit, then the command is rejected before any event is appended

### REQ-023: Could | Low | Observability
The backend SHOULD expose telemetry for key operational signals.

- AC-023-1: Given a command is dispatched, when it is processed, then Telemetry events are emitted for command duration, append latency, and projection lag
- AC-023-2: Given an aggregate actor restarts, when rehydration completes, then a Telemetry event is emitted with the event count replayed

---

## 4. Ambiguity Resolution Status

All 15 ambiguity markers have been resolved in this pass. Status of all items:

| # | Item | Status | Resolution |
|---|------|--------|-----------|
| 1 | REQ-001 AC-001-5 — Heartbeat timeout | ✓ Resolved | 60 seconds |
| 2 | REQ-002 AC-002-1 — Crash loop threshold | ✓ Resolved | 3 restarts within 5 minutes |
| 3 | REQ-003 AC-003-2 — Config propagation | ✓ Resolved | On next worker launch, not mid-run |
| 4 | REQ-007 AC-007-1 — Attach-bridge adapter | ✓ Resolved | Adapter normalizes before `Inbox.Poller` |
| 5 | REQ-009 AC-009-3 — PR sync fallback | ✓ Resolved | Polling fallback every 5 minutes |
| 6 | REQ-010 AC-010-2 — PR gate semantics | ✓ Resolved | Actively blocks progression |
| 7 | REQ-011 AC-011-4 — Scheduler crash window | ✓ Resolved | Recovery re-dispatches fire to new worker |
| 8 | REQ-012 AC-012-1 — Stuck-run threshold | ✓ Resolved | 15 minutes |
| 9 | REQ-013 AC-013-2 — VCS retry policy | ✓ Resolved | 3× exponential backoff, transient only |
| 10 | REQ-014 AC-014-3 — Secrets management | ✓ Resolved | Env vars dev/test; secrets manager prod |
| 11 | REQ-015 AC-015-1 — Template source | ✓ Resolved | Bundled with remote fallback |
| 12 | REQ-016 AC-016-2 — ProjectRegistry vs Aggregator | ✓ Resolved | Dedicated ProjectRegistry required |
| 13 | REQ-018 AC-018-1 — LiveView vs simpler surface | ✓ Resolved | LiveView required |
| 14 | REQ-022 AC-022-1 — Numeric run cap | ✓ Resolved | 100 concurrent active runs per project |
| 15 | Elicitation Q5 — Port vs rewrite taxonomy | ✓ Resolved | Rewrite/port/green-field taxonomy documented |

**Resolved: 15 · Open: 0 · Total: 15**
---

## 5. Dependency Map

- REQ-001 (worker runtime) → REQ-004 (run aggregate)
- REQ-002 (crash loop) → REQ-001
- REQ-003 (environment isolation) → REQ-001
- REQ-004 (run aggregate) → REQ-005 (phase aggregate)
- REQ-005 (phase aggregate) → independent
- REQ-006 (board item state machine) → independent
- REQ-007 (unified ingestion) → REQ-008
- REQ-008 (external triggers) → REQ-007
- REQ-009 (PR association) → REQ-004
- REQ-010 (PR gate) → REQ-009
- REQ-011 (recovery) → REQ-004, REQ-005, REQ-001
- REQ-012 (stuck detection) → REQ-011
- REQ-013 (VCS adapter) → REQ-004
- REQ-014 (environment configs) → independent (foundational)
- REQ-015 (workflow templates) → REQ-014
- REQ-016 (project registry/store/supervisor) → independent
- REQ-017 (planning flow) → REQ-016
- REQ-018 (debug views) → REQ-004, REQ-005
- REQ-019 (operations helpers) → REQ-004
- REQ-020 (test parity) → REQ-001 through REQ-019 (cross-cutting)
- REQ-021 (event store durability) → independent (foundational)
- REQ-022 (scale limits) → REQ-004
- REQ-023 (observability) → independent

**Clusters:**
- Worker cluster: REQ-001, REQ-002, REQ-003
- Run/Phase cluster: REQ-004, REQ-005, REQ-006
- Ingestion cluster: REQ-007, REQ-008
- PR cluster: REQ-009, REQ-010
- Recovery cluster: REQ-011, REQ-012
- Project infrastructure: REQ-016, REQ-017
- Config + observability are foundational and independent

---

## 6. Risks and Open Questions

### Risks
1. Consolidating three ingestion paths into inbox/poller may lose specialized behaviors of `attach_bridge.ex` and `migration_importer.ex` not representable in the inbox model. **Mitigated:** an adapter layer normalizes payloads before routing to `Inbox.Poller`, but the adapter must be verified against existing `attach_bridge.ex` behavior during porting.
2. Absent `pr_monitor.ex` means PR state sync is webhook-first — if GitHub webhooks are missed or reordered, PR state may become stale. **Mitigated:** periodic polling fallback reconciles state every 5 minutes (`REQ-009 AC-009-3`).
3. `recovery.ex` scheduler fire-and-track: if the scheduler crashes between recording intent (`ScheduledFireRecorded`) and worker pickup (`ScheduledFireConfirmed`), the fire may be lost. **Mitigated:** recovery re-dispatches the fire to a new worker (`REQ-011 AC-011-4`).
4. Test parity (35 files) is a large surface area; inadequate coverage risks undetected regressions.
5. Postgres data checksums detect corruption on read but do not prevent silent confirmed writes.
6. Hard run limit enforcement at aggregate level may cause thundering-herd rejection under load.
7. ProjectRegistry is absent — if `Aggregator.supervisor` is insufficient for project process supervision, runs may go unmonitored. **Mitigated:** dedicated `ProjectRegistry` required (`REQ-016 AC-016-2`).
8. VCS adapter abstraction may not cover all GitHub Enterprise scenarios without significant extension.
9. LiveView debug pages add a Phoenix Presence dependency — LiveView is required per `REQ-018 AC-018-1`.
10. Environment config changes for running workers may require worker restart to take effect.
11. Board item state machine (`board_item_state_machine.ex`) is a pre-CQRS module — fresh rewrite may miss subtle transition rules.
12. Simulation harness (`simulation_harness.ex`) supports load/chaos testing — without it, system behavior under failure is unverified.


### Open Questions

All ambiguity markers have been resolved in this pass. No open items remain.
## 7. Self-Critique

The following issues were identified during this refinement pass. Issues marked ✓ are resolved; issues marked ⚠ are partially resolved or remain open.

1. ~~**Worker heartbeat timeout unspecified**~~ ✓ **RESOLVED** — heartbeat timeout set to 60s (`REQ-001 AC-001-5`).
2. ~~**Crash loop threshold unspecified**~~ ✓ **RESOLVED** — 3 restarts within 5 minutes pauses the run (`REQ-002 AC-002-1`).
3. ~~**Environment config propagation ambiguous**~~ ✓ **RESOLVED** — config changes apply on next worker launch, not mid-run (`REQ-003 AC-003-2`).
4. ~~**Attach-bridge consolidation may lose specialized behavior**~~ ✓ **RESOLVED** — adapter layer normalizes attach-bridge payloads into `InboxItem` before routing to `Inbox.Poller` (`REQ-007 AC-007-1`).
5. ~~**PR webhook-only sync may be insufficient**~~ ✓ **RESOLVED** — polling fallback confirmed; every 5 minutes (`REQ-009 AC-009-3`).
6. ~~**PR gate semantics unclear**~~ ✓ **RESOLVED** — PR gate actively blocks run progression when status is not acceptable (`REQ-010 AC-010-2`).
7. ~~**Scheduler crash window unresolved**~~ ✓ **RESOLVED** — recovery re-dispatches fire to new worker (`REQ-011 AC-011-4`).
8. ~~**Stuck-run threshold unspecified**~~ ✓ **RESOLVED** — 15 minutes with no phase or worker events marks a run stuck (`REQ-012 AC-012-1`).
9. ~~**VCS retry policy unspecified**~~ ✓ **RESOLVED** — 3 retries with exponential backoff for transient failures; non-transient failures not retried (`REQ-013 AC-013-2`).
10. ~~**Per-subsystem port vs rewrite mix unresolved**~~ ✓ **RESOLVED** — gap-closure approach documented: rewrite coupled modules, port pure adapters/helpers, green-field for new capability (`Elicitation decisions`).
11. ~~**Run cap per project unspecified**~~ ✓ **RESOLVED** — 100 concurrent active runs per project (`Elicitation decisions`).
12. ~~**Secrets management unspecified**~~ ✓ **RESOLVED** — secrets manager in prod; environment variables in dev/test (`REQ-014 AC-014-3`).

All 12 self-critique items are resolved. No open items remain.

## 8. Acceptance Criteria Summary
| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---|
| REQ-001 | Worker runtime (fresh rewrite) | Must | High | 5 |
| REQ-002 | Crash loop detection | Must | Medium | 2 |
| REQ-003 | Worker environment isolation | Should | Medium | 2 |
| REQ-004 | Run state-machine aggregate | Must | High | 4 |
| REQ-005 | Phase state-machine aggregate | Must | High | 3 |
| REQ-006 | Board item state machine | Must | Medium | 2 |
| REQ-007 | Unified ingestion (consolidate 3 paths) | Must | High | 4 |
| REQ-008 | External trigger ingestion | Should | Medium | 2 |
| REQ-009 | PR association + GitHub webhook sync | Must | High | 3 |
| REQ-010 | PR gate enforcement | Should | Medium | 2 |
| REQ-011 | Recovery scanner + fire-and-track scheduler | Must | High | 4 |
| REQ-012 | Stuck-run detection | Should | Medium | 1 |
| REQ-013 | VCS adapter abstraction | Must | High | 3 |
| REQ-014 | Environment configuration parity | Must | Medium | 3 |
| REQ-015 | Workflow template parity | Should | Medium | 2 |
| REQ-016 | Project registry, store, supervisor | Must | High | 3 |
| REQ-017 | Planning flow coordinator | Should | Low | 2 |
| REQ-018 | LiveView debug pages | Should | Low | 1 |
| REQ-019 | Operations helpers | Should | Low | 1 |
| REQ-020 | Test suite parity (35 files) | Must | High | 5 |
| REQ-021 | Event store durability + gap detection | Must | High | 3 |
| REQ-022 | Scale limit enforcement | Must | High | 2 |
| REQ-023 | Observability (telemetry) | Could | Low | 2 |

---

## 9. Implementation Readiness Gate

| Dimension | Score (1–5) | Prior |
|---|---|---|
| Completeness | 4 | 3 |
| Testability | 4 | 3 |
| Clarity | 4 | 3 |
| Feasibility | 4 | 4 |

**Overall: 4.0 — PASS**
**Resolved this pass (15 items):** heartbeat timeout (60s), crash loop threshold (3×/5 min), environment config propagation (next launch), attach-bridge adapter policy, PR sync polling interval (5 min), PR gate semantics (active block), scheduler crash recovery (re-dispatch to new worker), stuck-run threshold (15 min), VCS retry policy (3× exponential backoff), per-subsystem gap-closure taxonomy (rewrite/port/green-field), run cap (100 concurrent per project), secrets management (env vars in dev/test; secrets manager in prod), workflow template source (bundled + remote fallback), ProjectRegistry (dedicated module required), LiveView debug pages (LiveView required).

**Remaining open items: 0**

**Gate decision: PASS at 4.0.** All 15 ambiguity markers resolved in this pass. No open items remain. No new ambiguity markers may be introduced during implementation.
---

*Generated: 2026-07-29 | Document ID: PRD-2026-7b4a3944 | Scale: DEEP | Branch: `feature/trd-2026-96872fc5-go-elixir-cqrs-parity` (`1e0ab345`) vs `main` (`bc6b4774`)*
