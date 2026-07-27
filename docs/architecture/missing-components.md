# Missing Components for the New Architecture

**Branch:** `slices/go-elixir-cqrs` @ `6489b3d2`
**Purpose:** From the [gap analysis](./functional-gap-analysis.md), identify every component that
must exist — built, migrated, or explicitly replaced — for the new Go CLI + Elixir ES/CQRS
backend to be functionally equivalent to `main`. AC1–AC6 are architecture validation milestones,
not the parity boundary.

> **Goal:** A robust, functionally equivalent backend. The spike's closed loop (Project →
> Task → Run → Worker → Projection) is the core. Every capability `main` exposes externally
> must either be present in the new system, or have an explicit replacement that transfers
> its behavior to Go, Elixir, or a different layer.

---

## How to Read This Document

Each component is classified as:

| Class | Meaning |
|---|---|
| **Platform** | Must exist before any domain capability can be tested |
| **Domain parity** | `main` capability that must work in the new system (may be implemented differently) |
| **Operational** | Production readiness — monitoring, safety, persistence |
| **Explicit replacement** | Behavior moved from one layer/component to another |

Components are ordered within their phase. Phases must be completed in order within a row
of the dependency graph.

---

## Phase 1 — Core Platform

These must exist before any domain capability or integration test can run.

### 1. HTTP API (Phoenix) — Platform

**What must exist:**
- `POST /api/commands` — Go CLI submits any command; Phoenix dispatches to `CommandRouter`
- `GET /api/projects/:id` → `ProjectionStore.project/1`
- `GET /api/tasks/:id` → `ProjectionStore.task/1`
- `GET /api/runs/:id` → `ProjectionStore.run/1`
- `GET /api/projects` → `ProjectionStore.project_list/0`
- `GET /api/tasks` → `ProjectionStore.task_list/0`
- `GET /api/runs` → `ProjectionStore.run_list/0`

**Why:** Without HTTP, the Go CLI cannot send commands or query results. The new architecture
moves all state mutation to `CommandRouter` via Phoenix. This is not optional.

**Gap:** `Http.Endpoint` and all controllers are absent. Phoenix is not in `mix.exs` deps.
`CommandRouter` exists but has no HTTP surface.

**Implementation:** Phoenix endpoint + `CommandController` (POST) + `QueryController` (GETs).
Each query controller reads only from `ProjectionStore`.

---

### 2. Typed Event Structs + EventCodec — Platform

**What must exist:**
- `@enforce_keys`, `@type t`, `@derive Jason.Encoder` on every authoritative event module
- `ForemanServer.EventCodec.decode!/2` with one clause per event type
- `apply_event` in every aggregate pattern-matching on typed structs (not `case Aggregate.event_type`)
- Worker protocol restricted to a closed set of typed command types

**Why:** Article IX (constitution) requires every authoritative domain event to be a typed
struct. Without this, `apply_event` cannot be reliably tested, replay cannot be validated,
and optimistic concurrency (AC3) cannot be verified.

**Event inventory — scope and limitations:**
The table below covers events emitted by aggregates (verified via literal `event_type: "…"` assignments
in `handle_command`). It does **not** include events recognized in `apply_event` that are
emitted by other aggregates (e.g. `RunCompleted` is recognized in both `Worker` and `Run`).
Additionally, `worker.record` accepts an arbitrary `event_type` from the command payload — the full
vocabulary cannot be enumerated statically until that channel is closed.

**`events/` directory:** 10 modules exist (~14% of enumerated emitted types). None use
`@enforce_keys` or `@type t`. `RunCompleted` is `defstruct []`.

**Event types emitted by aggregates:**

| Event Type | Aggregate | Event Module? | Notes |
|---|---|---|---|
| `ProjectRegistered` | Project | ✓ | fielded, no @enforce_keys/@type t |
| `ProjectUpdated` | Project | ✗ | missing |
| `ProjectArchived` | Project | ✓ | fielded, no @enforce_keys/@type t |
| `ProjectReactivated` | Project | ✗ | missing |
| `TaskCreated` | Task | ✓ | fielded, no @enforce_keys/@type t |
| `TaskUpdated` | Task | ✗ | missing |
| `TaskClosed` | Task | ✓ | fielded, no @enforce_keys/@type t |
| `TaskDependencyAdded` | Task | ✗ | missing |
| `TaskAnnotated` | Task | ✗ | missing |
| `RunStarted` | Run | ✓ | fielded, no @enforce_keys/@type t |
| `RunUpdated` | Run | ✗ | missing |
| `RunCompleted` | Run | ✓ | `defstruct []` — empty, must be fielded |
| `RunDeleted` | Run | ✗ | missing |
| `RunFailed` | Run | ✗ | missing |
| `RunBlocked` | Run | ✗ | missing |
| `PhaseStarted` | Phase | ✓ | fielded, no @enforce_keys/@type t |
| `PhaseCompleted` | Phase | ✓ | fielded, no @enforce_keys/@type t |
| `PhaseFailed` | Phase | ✗ | missing (static map in handle_command) |
| `PhaseTimedOut` | Phase | ✗ | missing (static map in handle_command) |
| `PhaseRetried` | Phase | ✗ | missing (static map in handle_command) |
| `PhaseSkipped` | Phase | ✗ | missing (static map in handle_command) |
| `PhaseReportProduced` | ArtifactReport | ✗ | missing |
| `PhaseVerdict` | ArtifactReport | ✗ | missing |
| `WorkerStarted` | Worker | ✓ | fielded, no @enforce_keys/@type t |
| `WorkerExited` | Worker | ✓ | fielded, no @enforce_keys/@type t |
| `ToolCallRequested` | ToolCall | ✗ | missing |
| `ToolCallApproved` | ToolCall | ✗ | missing (conditional if/else) |
| `ToolCallDenied` | ToolCall | ✗ | missing (conditional if/else) |
| `ToolCallFinished` | ToolCall | ✗ | missing |
| `SchedulerTicked` | Scheduler | ✗ | missing |
| `SchedulerTaskClaimed` | Scheduler | ✗ | missing |
| `SchedulerTaskSkipped` | Scheduler | ✗ | missing |
| `InteractiveRecoveryResumed` | Recovery | ✗ | missing |
| `RecoveryResolved` | Recovery | ✗ | missing |
| `PlanningFlowStarted` | PlanningFlow | ✗ | missing |
| `PlanningFlowCompleted` | PlanningFlow | ✗ | missing |
| `PlanningTraceLinked` | PlanningFlow | ✗ | missing |
| `IntegrationCommandIngested` | Integration | ✗ | missing (variable event_type) |
| `IntegrationConfigured` | Integration | ✗ | missing (variable event_type) |
| `IntegrationSyncRequested` | Integration | ✗ | missing |
| `IntegrationSyncCompleted` | Integration | ✗ | missing |
| `MigrationImportStarted` | Migration | ✗ | missing |
| `MigrationImportCompleted` | Migration | ✗ | missing |
| `MigrationRecordImported` | Migration | ✗ | missing |
| `InboxMessageAppended` | Inbox | ✗ | missing |
| `InboxDeliveryUpdated` | Inbox | ✗ | missing |
| `ExternalTriggerCommand` | ExternalTrigger | ✗ | missing (variable event_type) |
| `CommandAccepted` | ExternalTrigger | ✗ | missing (variable event_type) |
| `ExternalWorkerObserved` | ExternalTrigger | ✗ | missing (variable event_type) |
| `NeedsOperator` | OperatorIntervention | ✗ | missing |
| `HumanInterruptionRecorded` | OperatorIntervention | ✗ | missing |
| `MergeBlocked` | VcsOperation | ✗ | missing |
| `MergeFailed` | VcsOperation | ✗ | missing |
| `PrReady` | VcsOperation | ✗ | missing |
| `PrUpdated` | VcsOperation | ✗ | missing |
| `PrMerged` | VcsOperation | ✗ | missing |
| `PrReset` | VcsOperation | ✗ | missing |
| `PrRetargeted` | VcsOperation | ✗ | missing |
| `PrGateObserved` | VcsOperation | ✗ | missing |
| `VcsMergeRequested` | VcsOperation | ✗ | missing |
| `WorktreeCreated` | VcsOperation | ✗ | missing |
| `WorktreeCleaned` | VcsOperation | ✗ | missing |
| `AttachRequested` | Attachment | ✗ | missing |
| `AttachUnsupported` | Attachment | ✗ | missing |
| `WorkerFailureSimulated` | Worker | ✗ | missing |
| `WorkerReattached` | Worker | ✗ | missing |
| `WorkerRecoveryRequired` | Worker | ✗ | missing |
| `WorkerRestarted` | Worker | ✗ | missing |

**Gap summary:** 10 existing modules need `@enforce_keys` + `@type t` added.
`RunCompleted` must become fielded. ~60+ new modules must be created across the 18 aggregate
domains. The total cannot be stated precisely until the Worker forwarding channel is closed.

**Worker protocol — open forwarding channel (must be closed before total is known):**
`Worker.handle_command/2` (`worker.ex:117-130`) reads `event_type` directly from the command
payload and emits it without validation. This is an open-ended channel: any string can be
forwarded as an authoritative event. Article IX prohibits untyped authoritative events.

Additionally, `Worker.apply_event/2` recognizes events from other aggregates that are **not**
emitted by `Worker` itself (cross-aggregate replay):
`ToolCallFinished`, `AssistantMessage`, `WorkerStdout`, `WorkerStderr`, `RunCompleted`,
`RunFailed` — none of these are emitted by `Worker`, but the aggregate must handle them on replay.

**Required resolution before item can be closed:**
1. Replace `worker.record`'s arbitrary `event_type` forwarding with a closed vocabulary of typed
   command types (e.g. `worker.start`, `worker.heartbeat`, `worker.exit`, `worker.stdout.append`,
   `worker.stderr.append`, `worker.message`). Each maps to a specific typed output event.
2. Add typed event modules for all worker-recognized events: `ToolCallFinished`,
   `AssistantMessage`, `WorkerStdout`, `WorkerStderr`
3. Enumerate the closed worker event vocabulary — this becomes the definitive set replacing
   the open forwarding channel
4. Then the total event module count becomes statable

**EventCodec scope:** One clause per authoritative event type (final count TBD after
Worker protocol is closed). Pass-through: `decode!(event_type, %TypedStruct{})`. JSON-map:
validate string keys, reject unknown keys, build typed struct.

### 3. ProjectionStore Full Query Layer — Platform

**What must exist:**

| Function | Stores | Needed by |
|---|---|---|
| `project/1` | `project_id`, `path`, `status`, `archived?` | Go CLI: `project list`, `project info` |
| `task/1` | `task_id`, `project_id`, `status` | Go CLI: `task list`, `task info`, AC5 |
| `run/1` | `run_id`, `task_id`, `status`, `current_phase`, `pr_url`, `completed_at` | Go CLI: `run list`, `run info`, AC4, AC5 |
| `project_list/0` | all active projects | Go CLI: `project list` |
| `task_list/0` | all tasks | Go CLI: `task list` |
| `run_list/0` | all runs | Go CLI: `run list` |

**Event handlers required in `ProjectionStore`:**
`ProjectRegistered`, `ProjectArchived`, `ProjectReactivated`,
`TaskCreated`, `TaskUpdated`, `TaskClosed`,
`RunStarted`, `RunCompleted`, `RunFailed`, `RunDeleted`,
`PhaseStarted`, `PhaseCompleted`

**Gap:** Only `project/1` is implemented. `task/1`, `run/1`, and all `*_list/0`
functions are absent. Only 3 event types are handled; 12+ are missing.

---

## Phase 2 — Domain Capability Parity

Every capability `main` exposes externally via the Go/Node CLI or HTTP must work
in the new system. Implementation may differ; the behavior must be present.

### 4. Worker Lifecycle + Supervision — Domain Parity

**What must work:**
- Workers register on startup (`worker.start`)
- Workers send heartbeats while running (`worker.event` with heartbeat payload)
- `Overwatch` detects dead workers (no heartbeat within threshold)
- Dead workers are cleaned up; their runs are marked `failed` or `stuck`
- Worker status (active / idle / dead) is queryable via `ProjectionStore`

**Why:** Without worker supervision, runaway workers are invisible. A run can be stuck
waiting for a worker that died silently. `main` has this; parity requires it.

**Gap:** `Overwatch` GenServer is absent. `WorkerHeartbeat` events are not handled in
`ProjectionStore`. The `Worker` aggregate exists but is not exercised.

**Note:** The spike's AC tests a single aggregate actor. Worker supervision involves
multiple concurrent workers — a different test shape than AC1, but the same architecture.

---

### 5. Run → Phase → Worker Closed Loop — Domain Parity

**What must work:**
- `run.start` creates a run and spawns a worker
- `phase.start` / `phase.complete` update the current phase
- `run.complete` marks the run terminal with `status: "completed"`
- Worker completion is routed as a command through `CommandRouter` (not a direct write)
- The Go CLI can query run and phase state at any point

**Why:** This is the core orchestration loop. AC5 tests a simplified version of this.
The full loop includes multi-phase runs, worker exit, and failure handling.

**Gap:** The aggregates exist (`Run`, `Phase`, `Worker`) but are not wired into
`CommandRouter` for the full loop. No HTTP integration test exists. `run.complete`
has not been tested via HTTP.

---
### 6. Workflow + Prompt Runtime — Domain Parity

**What must exist:**
- YAML workflow defines ordered phase names; `WorkflowInterpreter` maps phase names to execution steps
- Prompt resolver: given `(workflow, phase)`, selects the end-user override or bundled prompt via the existing resolution chain; validates against required phase markers
- Prompt loader: reads the selected prompt file, renders `{{variable}}` templates with context inputs (run id, project id, phase id, etc.)
- Rendered prompt (or a content-addressed artifact of it) stored and replayed as-is on restart/resumption — a hash alone only detects drift
- Immutable workflow and prompt content hashes captured in run/phase events at execution start
- `foreman init --force` refresh of installed workflows/prompts (verified in `main`'s `src/cli/commands/init.ts`)
- Dispatch staleness gate: `foreman run` fails fast if installed workflow/prompt hashes are stale (documented in AGENTS.md; `Doctor.checkWorkflows()` exists on `main` but is not wired as a dispatch gate)
- `Phase` aggregate enforces phase lifecycle and invariants; the prompt resolver handles override resolution, loading, and rendering — phase behavior is not hardcoded in the aggregate

**Why:** `main` has two separate prompt/workflow systems. The Node CLI has `prompt-loader.ts` (`loadPrompt`, `renderTemplate`, `checkStalePrompts`, `REQUIRED_PHASES`, `installBundledPrompts`). The Elixir `WorkflowInterpreter` loads YAML with a `prompt` field but treats it as inline string metadata and does not call the Node CLI loader. Bridging them requires: the Elixir side adopts the `(workflow, phase)` prompt resolution, renders with context, stores the rendered content (or a content-addressed artifact) for replay, and captures hashes in events. `foreman init --force` is verified in `main`'s `init.ts`.

**Gap:** No `WorkflowInterpreter` on the slice. No prompt resolver wired to the Elixir backend. No template rendering on the Elixir side. No immutable rendered prompt or content-addressed artifact stored for replay. No dispatch staleness gate.

**Dependency:** Item 1 (HTTP API), Item 3 (ProjectionStore), Item 5 (Run/Phase loop) must be complete before this can be tested end-to-end.

### 7. PR Monitor + VCS Workflow — Domain Parity

**What must work:**
- After `run.complete`, the system monitors a GitHub PR URL
- `PrMonitor` watches PR state (opened, merged, closed, conflict)
- `PrCreated` event records the PR URL on the run
- `PrMerged` / `PrClosed` events update run status accordingly
- Go CLI can set the PR URL on a run; can query PR status

**Why:** `main` does this. The Go CLI uses `foreman run` with a PR branch. The user
expects PR status to be visible. If this is removed, the system cannot be used for
the PR → run → merge workflow.

**Replacement note:** The spike spec says VCS mutation moves to Go. But PR *monitoring*
(reading GitHub, emitting events) may live in Elixir or Go. Decision needed:
- Option A: Go polls GitHub, sends `pr.update` commands to Elixir
- Option B: Elixir's `PrMonitor` polls GitHub, emits events (current `main` behavior)
- Option C: A separate lightweight process (not full `PrMonitor`) handles polling

---

### 8. Planning Flow Commands — Domain Parity

**What must work:**
- `command_type: "plan.prd"` or `"plan.trd"` triggers planning flow
- `PlanningFlow` aggregate processes the planning document
- `PlanningFlowStarted`, `PlanningFlowCompleted` events are emitted
- Planning trace is linked to the run

**Why:** `main` supports planning flows as a command type. Removing this entirely
would break existing workflows. Either implement it or explicitly migrate it.

**Gap:** `PlanningFlow` aggregate exists but is not routed in `CommandRouter`.
No HTTP command path for planning commands.

---

### 9. Migration Import — Domain Parity

**What must work:**
- `command_type: "migration.import"` ingests a migration payload
- `MigrationImporter` processes the import and emits `MigrationImportStarted`,
  `MigrationRecordImported`, `MigrationImportCompleted`
- Events are appended to the event store — not skipped or stubbed

**Why:** `main` has this. Existing installations may depend on migration import.
If removed, existing data cannot be imported into the new system.

**Gap:** `MigrationImporter` aggregate exists but is not routed in `CommandRouter`.

---

### 10. Inbox + External Triggers — Domain Parity

**What must work:**
- External systems can trigger runs via an inbox endpoint
- `inbox.send` command creates an `InboxMessageAppended` event
- `ExternalTriggerCommand` routes to the appropriate aggregate
- Inbox delivery status is tracked (`InboxDeliveryUpdated`)

**Why:** `main` has this for external integration. Removing it breaks webhook-based triggers.

**Gap:** `Inbox` aggregate and `IntegrationIngestion` are absent from the slice.

---

### 11. Recovery Engine — Domain Parity

**What must work:**
- After a server restart, the recovery engine detects interrupted runs
- `InteractiveRecoveryResumed` events are emitted to resume paused workflows
- The system can recover to a consistent state after a crash

**Why:** `main` has this. Without recovery, any server crash leaves runs in an indeterminate
state. Production use requires it.

**Gap:** `Recovery` aggregate exists but is not started in the application.
`recovery_engine_test.exs` is absent.

---

### 12. Scheduler Runtime — Domain Parity

**What must work:**
- `Scheduler` GenServer ticks periodically
- `SchedulerTicked` events are emitted
- `SchedulerTaskClaimed` / `SchedulerTaskSkipped` handle task scheduling
- Scheduled runs are triggered automatically

**Why:** `main` has this. Without a scheduler, all runs must be triggered manually.

**Gap:** `Scheduler` aggregate exists (with `tick/claim/skip` handlers) but is not
started in the application. `scheduler_test.exs` is absent.

---

## Phase 3 — Operational Robustness

Production-readiness components that `main` has and the new system must have.

### 13. EventStore Schema + Database Migrations — Operational

**What must exist:**
- EventStore tables created via `mix.event_store.init` or explicit migration scripts
- Schema ownership via `schema: "public"` (currently configured, not migrated)
- Up/down migration path for production deployment

**Gap:** The spike uses raw `schema: "public"` adapter config without running migrations.
Works in dev; not production-safe.

---

### 14. RuntimeSafety Validation — Operational

**What must exist:**
- `ForemanServer.RuntimeSafety.validate!/0` runs at application startup
- Validates that required configuration is present (env vars, adapter selection, etc.)
- Crashes the application on misconfiguration rather than failing silently

**Why:** `main` has this. Starting in a misconfigured state is worse than a hard failure.

**Gap:** `RuntimeSafety` is absent.

---

### 15. RuntimeInfo + Adapter Selection — Operational

**What must exist:**
- `ForemanServer.RuntimeInfo` selects between `:postgres` and `:memory` EventStore adapters
- `FOREMAN_RUNTIME_MODE` env var switches adapters
- Other adapters (VCS, etc.) also use `RuntimeInfo` for selection

**Why:** Enables in-memory for tests (fast), Postgres for production (durable).
Without it, switching environments requires code changes.

**Gap:** `RuntimeInfo` is absent. `main` uses it for EventStore, VCS, and other adapters.

---

### 16. Ecto Repo + Postgres-Backed Projections — Operational

**What must exist:**
- `ForemanServer.Repo` (Ecto) for direct database access
- `ProjectionStore.Postgres` backend that persists projections to Postgres
- `ProjectionStore` GenServer as an in-memory cache; Postgres as durable store
- Migrations for projection tables

**Why:** In-memory `ProjectionStore` is lost on restart. `main` uses Postgres for durable
projections. Production requires persistence.

**Gap:** `Repo`, `ProjectionStore.Postgres`, and all projection migrations are absent.

---

### 17. Provider Registry — Operational

**What must exist:**
- `ForemanServer.ProviderRegistry` tracks configured providers (VCS, CI, etc.)
- Providers are configurable at runtime
- Provider config is validated on startup

**Why:** `main` has this for multi-provider support.

**Gap:** `ProviderRegistry` is absent.

---

## Explicit Replacements

Where `main` behavior is explicitly transferred to a different layer or component.

| `main` behavior | Replacement | Owner |
|---|---|---|
| VCS mutations (create branch, push, PR) | Go CLI handles all VCS directly | Go |
| `ForemanStore` (Node orchestration state) | Gone — Elixir ES/CQRS is the source of truth | N/A |
| `writeElixirOrchestrationEvent` (Node bypass) | Gone — all writes go through `CommandRouter` | N/A |
| `Overwatch` (Node worker lifecycle) | Elixir `Overwatch` GenServer monitors workers | Elixir |
| Node/TypeScript worker protocol | Go worker sends `run.complete` as HTTP command | Go → Elixir |
| Node `vcs-backend` | Go `vcs` package | Go |

**Note:** Go as the VCS owner means the Go CLI creates branches, pushes commits, and opens PRs.
Elixir does not mutate VCS. But Elixir may still need to *monitor* PR state (see item 6 above).

---

## Implementation Phases

```
Phase 1 — Core Platform
  1. Phoenix HTTP API + Query Controllers
  2. Typed Event Structs + EventCodec
  3. ProjectionStore Full Query Layer
        ↓
Phase 2 — Domain Capability Parity
  4. Worker Lifecycle (Overwatch + heartbeat projection)
  5. Run → Phase → Worker Closed Loop
  6. Workflow + Prompt Runtime
  7. PR Monitor + VCS Workflow  ← depends on 1, 3, 5, 6
  8. Planning Flow Commands      ← depends on 1, 2, 3
  9. Migration Import           ← depends on 1, 2, 3
 10. Inbox + External Triggers  ← depends on 1, 2, 3
 11. Recovery Engine             ← depends on 1, 2, 3, 4
 12. Scheduler Runtime           ← depends on 1, 2, 3
        ↓
Phase 3 — Operational Robustness
 13. EventStore Schema + Migrations
 14. RuntimeSafety Validation
 15. RuntimeInfo + Adapter Selection
 16. Ecto Repo + Postgres-Backed Projections
 17. Provider Registry
```

**Dependency rule:** A component can be started when all components it depends on are
complete. Items within the same phase can be developed in parallel by separate agents.
---


## Test Coverage Required

Each Phase 1–3 component should have a corresponding test file. The current 2 tests
(AC1, AC2) validate the actor architecture only. The gap analysis identifies 30 test
files that existed on `main`; these are not "deferred" — they must be rewritten or
replaced for the new architecture:

| Test | Maps to component |
|---|---|
| `command_router_test.exs` | 1, 2, 5 |
| `projection_store_test.exs` | 3 |
| `projection_store_timeout_test.exs` | 3 |
| `run_actor_test.exs` | 5 |
| `worker_protocol_test.exs` | 4, 5 |
| `worker_launcher_test.exs` | 4 |
| `overwatch_test.exs` | 4 |
| `workflow_interpreter_test.exs` | 6 |
| `prompt_loader_test.exs` | 6 |
| `prompt_render_replay_test.exs` | 6 |
| `pr_monitor_test.exs` | 7 |
| `pr_gate_test.exs` | 7 |
| `planning_flow_test.exs` | 8 |
| `migration_importer_test.exs` | 9 |
| `inbox_test.exs` | 10 |
| `integration_ingestion_test.exs` | 10 |
| `attach_bridge_test.exs` | 10 |
| `recovery_engine_test.exs` | 11 |
| `scheduler_test.exs` | 12 |
| `runtime_safety_test.exs` | 14 |
| `runtime_info_test.exs` | 15 |
| `provider_registry_test.exs` | 17 |
| `foreman_init_fresh_test.go` | 6 |
| `foreman_run_staleness_test.go` | 6 |
| `foreman_prompt_override_e2e_test.go` | 6 |

**Note:** `vcs_adapter_test.exs` tests the old Node VCS adapter. VCS is now Go's domain;
that test is replaced by Go tests in the `cmd/foreman` package.

---

*Generated: 2026-07-27 | Based on gap analysis @ `6489b3d2`*
