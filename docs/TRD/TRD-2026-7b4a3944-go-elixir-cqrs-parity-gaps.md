---
document_id: TRD-2026-7b4a3944
version: 1.0.0
status: Draft
date: 2026-07-29
prd_reference: PRD-2026-7b4a3944
prd_version: 1.0.1
architecture_approach: Staged PR Slices (Option C — 7 slices)
total_tasks: 29
total_test_tasks: 17
design_readiness_score: 4.0
trd_micro_uuid: 7b4a3944
---

# TRD: Go/Elixir CQRS Slice — Functional Parity Gaps

## Architecture Decision

### Chosen Approach: Staged PR Slices (Option C)
Seven shippable PRs ordered by the dependency graph, each leaving the codebase test-green and independently reviewable.

### Alternatives Considered

**Option A — Minimal Incremental**
Must-only scope. Defers all Should/Could to a later phase. Fastest initial ship but leaves large functional gaps.

**Option B — Complete Gap Closure**
Full PRD scope in one coordinated push. Highest upfront effort, largest blast radius, highest risk of review delays.

**Option C — Staged PR Slices (Chosen)**
7 PRs ordered by dependency:
1. Shared inbox schema + project registry/store/supervisor + planning flow (foundational)
2. Phase aggregate + Run aggregate + BoardItemStateMachine (Phase ships first; others depend on it)
3. Overwatch worker runtime + crash loop + env isolation (depend on Run)
4. Unified ingestion + external triggers + PR lifecycle + recovery + VCS
5. Config parity + workflow templates
6. Debug/Ops (LiveView + operations helpers)
7. Test parity + NFRs (observability + scale limits)

**Key dependency resolution — REQ-007/008 cycle:**
The PRD dependency map shows REQ-007 → REQ-008 and REQ-008 → REQ-007. This is a genuine cycle. Resolution: TRD-001 (SharedInbox command/event schema) is added as a foundational task. Both ingestion (REQ-007) and external trigger polling (REQ-008) depend on the shared schema — not on each other. The cycle is broken at the schema layer.

### Rationale
- Matches the natural dependency graph
- Foundational work (project infra, SharedInbox schema, PlanningFlow) ships in PR1
- Phase aggregate (PR2) enables Run aggregate and BoardItemStateMachine (also PR2)
- Worker runtime (PR3) follows from Run aggregate (PR2)
- Ingestion and PR lifecycle share no direct dependencies, grouped in PR4
- Config parity is independent, ships in PR5
- Debug/Ops (PR6) follows the core feature PRs
- Test parity + NFRs are cross-cutting, shipped last (PR7)
---

## System Architecture

### Component Map

```
packages/foreman_server/
├── lib/
│   ├── foreman_server/
│   │   ├── aggregate/
│   │   │   ├── actor.ex          # existing — supervised GenServer
│   │   │   └── supervisor.ex     # existing — Aggregate supervisor
│   │   ├── command_router.ex     # existing — sole append point
│   │   ├── event_store.ex        # existing — Commanded adapter
│   │   ├── projection_store.ex    # existing
│   │   ├── recovery.ex           # existing — recovery scanner
│   │   ├── overwatch.ex          # rewrite (PR3)
│   │   ├── inbox/
│   │   │   ├── poller.ex         # existing
│   │   │   ├── shared_schema.ex  # new — TRD-001/TRD-006 (SharedInbox schema + ingestion)
│   │   │   ├── attach_bridge.ex  # new — TRD-014
│   │   │   └── migration_importer.ex # new — TRD-014
│   │   ├── aggregates/
│   │   │   ├── project.ex        # new — TRD-005
│   │   │   ├── run.ex            # new — TRD-009
│   │   │   ├── phase.ex          # new — TRD-008
│   │   │   ├── board_item_state_machine.ex # new — TRD-010
│   │   │   ├── planning_flow.ex  # new — TRD-007
│   │   │   ├── run_aggregate.ex # alias/resolver — TRD-009
│   │   │   └── phase_aggregate.ex # alias/resolver — TRD-008
│   │   ├── project/
│   │   │   ├── registry.ex       # new — TRD-002
│   │   │   ├── store.ex          # new — TRD-004
│   │   │   └── supervisor.ex     # new — TRD-003
│   │   ├── vcs/
│   │   │   └── adapter.ex        # new — TRD-018
│   │   ├── pr/
│   │   │   ├── associate.ex     # existing — expand — TRD-016
│   │   │   ├── gate.ex           # new — TRD-017
│   │   │   └── monitor.ex        # new — TRD-017
│   │   ├── scheduler/
│   │   │   └── runtime.ex        # new — TRD-021
│   │   ├── debug/
│   │   │   └── views.ex          # new — TRD-026
│   │   └── operations/
│   │       └── helpers.ex        # new — TRD-027
│   ├── events/                   # 84 existing typed events
│   └── commands/                 # 11 existing typed commands
├── config/
│   ├── config.exs                # existing
│   ├── dev.exs                   # new — TRD-022
│   ├── test.exs                  # new — TRD-023
│   └── prod.exs                  # new — TRD-024
├── priv/
│   └── defaults/workflows/        # 6 YAML templates — TRD-025
└── test/
    ├── foreman_server/
    │   ├── overwatch_test.exs            # new — TRD-011-TEST
    │   ├── recovery_test.exs             # existing — expand — TRD-019-TEST
    │   ├── run_aggregate_test.exs       # new — TRD-009-TEST
    │   ├── phase_aggregate_test.exs     # new — TRD-008-TEST
    │   ├── board_item_state_machine_test.exs # new — TRD-010-TEST
    │   ├── ingestion_test.exs            # new — TRD-033-TEST
    │   ├── pr_lifecycle_test.exs         # new — TRD-034-TEST
    │   ├── vcs_adapter_test.exs          # new — TRD-035-TEST
    │   ├── project_infra_test.exs        # new — TRD-036-TEST
    │   ├── config_parity_test.exs        # new — TRD-037-TEST
    │   ├── workflow_templates_test.exs   # new — TRD-025-TEST
    │   ├── planning_flow_test.exs       # new — TRD-007-TEST
    │   ├── worker_environment_test.exs  # new — TRD-013-TEST
    │   ├── telemetry_test.exs           # new — TRD-040-TEST
    │   ├── durability_scale_test.exs    # new — TRD-041-TEST
    │   └── operations_helpers_test.exs  # new — TRD-027-TEST
    ├── foreman_server_web/live/
    │   └── debug_views_test.exs         # new — TRD-026-TEST
    └── architecture/
        └── event_store_enforcement_test.exs # existing — expand
```

### Data Flow

```
Caller (Phoenix HTTP)
    │
    ▼
CommandRouter.dispatch(command)   ◄── sole append point
    │
    ├──► Aggregate.Actor          ◄── supervised GenServer
    │         │
    │         ├──► aggregate_module.handle_command(state, cmd)
    │         │         │
    │         │         └──► returns event_spec or {:ok, nil}
    │         │
    │         └──► aggregate_module.apply_event(state, event)
    │
    └──► EventStore.append_to_stream   ◄── Commanded adapter

ProjectionStore   ◄── Projection handlers consume events
Recovery          ◄── Scans projections on startup
Overwatch         ◄── Tracks worker liveness; emits WorkerHeartbeat/Exited
ProjectRegistry   ◄── Name-to-pid mapping for project process tree
ProjectSupervisor ◄── OTP supervisor for project process tree
```

### Key Design Decisions

1. **All mutations route through `CommandRouter`** — no direct `append_to_stream`. Architecture test `event_store_enforcement_test.exs` enforces this.
2. **Aggregate state always a `%State{}` struct** — `%State{state | field: value}` updates; no `Map.merge`; no `struct/2`.
3. **Event structs typed** — `@enforce_keys`, `@type t`, `@derive Jason.Encoder`.
4. **Project infrastructure is dedicated** — `ProjectRegistry` + `ProjectSupervisor` are not shared with `Aggregator.supervisor`.
5. **Ingestion cycle broken at schema layer** — `SharedInbox` command/event schema is the common dependency for both ingestion paths.
6. **VCS adapter is an abstraction** — routes through `CommandRouter`, emits typed events, retries 3× exp backoff for transient failures.

---

## Master Task List

### PR 1: Shared Inbox Schema + Project Infrastructure
**Shippable State:** Projects can be registered and supervised; a shared inbox command/event schema is available for both ingestion paths and external triggers.

- [ ] **TRD-001** SharedInbox command and event schema | 2h | [satisfies ARCH] | Validates: — | AC: Define `StartInboxItem` command struct, `InboxItemStarted` event struct, `InboxItemCorrelationId` behaviour for dedupe; both attach-bridge ingestion and external trigger polling depend on this schema — not on each other
  - [ ] `InboxItemStarted` event: `%InboxItemStarted{correlation_id, source, payload, timestamp}`
  - [ ] `InboxItemDeduped` event: `%InboxItemDeduped{correlation_id, source}`
  - [ ] Dedupe window configurable via `:inbox_dedupe_window_seconds`
  - [ ] New `SharedInbox` module under `foreman_server/inbox/`
  - [ ] `InboxItemCorrelationId` behaviour: `correlation_id(command_or_payload) :: String.t()`

- [x] **TRD-002** ProjectRegistry | 4h | [satisfies REQ-016] | Validates: AC-016-2 | AC: Given a project process registers, when it calls `ProjectRegistry.register/2`, then the canonical name-to-pid map is updated; lookup by project_id returns the pid; unregister on termination
  - [x] `ProjectRegistry` GenServer with `register/2`, `unregister/1`, `lookup/1`
  - [x] Uses `Registry` under `:project_registry` registry
  - [x] `via(project_id)` helper for `GenServer.start_link`

- [x] **TRD-003** ProjectSupervisor | 3h | [satisfies REQ-016] | Validates: AC-016-1 | AC: Given a project is registered, when `ProjectSupervisor.start_project/1` is called, then it starts the full project process tree under this supervisor; crashed project processes are restarted
  - [x] `ProjectSupervisor` OTP supervisor — `restart: :permanent`, strategy `:one_for_one`
  - [x] `start_project/1` starts the project aggregate actor under this supervisor
  - [x] Monitors `ProjectRegistry` for pid→process mapping

- [x] **TRD-004** ProjectStore | 4h | [satisfies REQ-016] | Validates: AC-016-3 | AC: Given project configuration is persisted, when `ProjectStore.save/2` is called, then a `ProjectRegistered` or `ProjectUpdated` event is appended through CommandRouter and projected via ProjectionStore
  - [x] `ProjectStore` module — appends events via `CommandRouter`
  - [x] `ProjectStore.list/0` reads from `ProjectionStore`
  - [x] `ProjectStore.get/1` reads a single project projection

- [x] **TRD-005** Project aggregate | 3h | [satisfies REQ-016] | Validates: AC-016-1, AC-016-2, AC-016-3 | AC: Given a project aggregate is started, when `RegisterProject` command is dispatched, then `ProjectRegistered` event is appended; `ProjectUpdated` command updates config; aggregate uses `%State{}` struct
  - [x] `ForemanServer.Aggregates.Project.State` struct
  - [x] `handle_command/2` for `RegisterProject`, `UpdateProject`, `ArchiveProject`
  - [x] `apply_event/2` using `%State{state | ...}` updates

- [x] **TRD-006** Integration ingestion via inbox/poller | 3h | [satisfies REQ-007] | Validates: AC-007-2, AC-007-4 | AC: Given an integration ingestion webhook arrives, when it is received, then `SharedInbox.ingest/2` normalizes to an `InboxItem` and routes through `Inbox.Poller`; deduped items emit `InboxItemDeduped` and return existing delivery status
  - [x] `SharedInbox.ingest/2` calls `InboxItemCorrelationId` behaviour
  - [x] Routes normalized item to `Inbox.Poller`
  - [x] Tests: dedupe hit returns existing status without re-processing (`InboxItemStarted` count stays 1, `InboxItemDeduped` count grows)

- [x] **TRD-007** PlanningFlow aggregate | 3h | [satisfies REQ-017] | Validates: AC-017-1, AC-017-2 | AC: Given `plan.prd` or `plan.trd` command is dispatched, when `PlanningFlow.handle_command/2` processes it, then `PlanningFlowStarted` event is appended through CommandRouter; trace events append through existing aggregate infrastructure
  - [x] `ForemanServer.Aggregates.PlanningFlow.State` struct
  - [x] `handle_command/2` for planning commands
  - [x] `apply_event/2` using `%State{state | ...}` updates

---

### PR 2: Phase Aggregate + Run Aggregate + BoardItemStateMachine
**Shippable State:** Phases can be started and completed with optimistic concurrency; runs can transition through active/terminal states with idempotent complete; board items enforce valid status transitions.

- [ ] **TRD-008** Phase aggregate | 5h | [satisfies REQ-005] | Validates: AC-005-1, AC-005-2, AC-005-3 | AC: Given a phase is active, when `StartPhase` is dispatched, then `PhaseStarted` is appended and state transitions to active; given two `CompletePhase` commands race, when the second append uses wrong expected version, then append fails with concurrency conflict and actor retries with correct version
  - [x] `ForemanServer.Aggregates.Phase.State` struct (includes `exists?` — `PhaseStarted` without `run_id` still marks `exists?: true`)
  - [x] `handle_command/2` for `StartPhase`, `CompletePhase`, `FailPhase`, `SkipPhase`
  - [x] `apply_event/2` using `%State{state | ...}` — no `Map.merge`
  - [x] AC-005-3 router+EventStore concurrency test: two `phase.complete` specs routed before append, first succeeds, second gets `{:conflict, [expected: 1, actual: 2]}`, fresh route sees terminal state
  - [ ] Optimistic concurrency in `Actor` (already handles expected_version conflict — verify with AC-005-3 test)
  - [ ] Idempotent duplicate command handling via `command_id` (already in `Actor` — verify)

- [ ] **TRD-009** Run aggregate | 6h | [satisfies REQ-004] | Validates: AC-004-1, AC-004-2, AC-004-3, AC-004-4 | AC: Given a run is active, when `CompleteRun` dispatched on a terminal run, then `RunAlreadyCompleted` event is appended and state unchanged (idempotent); given run aggregate restarts, when `Aggregate.load/2` is called, then full stream is replayed and correct terminal/non-terminal state is restored
  - [x] `ForemanServer.Aggregates.Run.State` struct with fixed fields (`run_id`, `task_id`, `project_id`, `current_phase`, `phase_order`, PR fields) and dynamic maps (`phase_status`, `worker_status`, `retry_history`)
  - [x] `handle_command/2` for `StartRun`, `CompleteRun`, `FailRun`
  - [ ] `handle_command/2` for `CancelRun` (`run.cancel`/`RunCancelled` not in codebase)
  - [x] `apply_event/2` using `%State{state | ...}` updates — no `Map.merge`
  - [x] `RunAlreadyCompleted` spec emitted (state unchanged) when `run.complete` routes against a terminal run; `apply_event` for `RunAlreadyCompleted` is a no-op
  - [x] Replay via `Aggregate.load/2` restores terminal and non-terminal state correctly (4 tests)

- [x] **TRD-010** BoardItemStateMachine aggregate | 4h | [satisfies REQ-006] | Validates: AC-006-1, AC-006-2 | AC: Given an invalid status transition (e.g., `closed` → `in_progress`), when the command is dispatched, then it is rejected with `:invalid_transition` error
  - [x] `ForemanServer.Aggregates.BoardItemStateMachine.State` struct with `exists?`, `board_item_id`, `status`, `terminal?`
  - [x] Valid transitions: `backlog → in_progress → in_review → done`; `backlog → blocked → backlog`; `done` is terminal
  - [x] `handle_command/2`: `board_item.create` (require_absent), `board_item.transition` (require_exists + valid_transition guard)
  - [x] `apply_event/2` using `%State{state | ...}` updates — typed struct clause, unwrap clause, legacy map fallback
  - [x] BoardItemStatusChanged event struct registered in EventCodec for typed replay
  - [x] AggregateRouter: `board_item.*` → `BoardItemStateMachine`
  - [x] Test: invalid transition `done → in_progress` returns `{:error, :invalid_transition}` via router; terminal done rejects; valid chains; `Aggregate.load/2` replay
---

### PR 3: Overwatch Worker Runtime + Crash Loop + Env Isolation
**Shippable State:** Workers are launched and tracked with OTP supervision; zombie workers are cleaned up and crash loops are detected; workers receive isolated environment configs.

- [ ] **TRD-011** Overwatch worker runtime (rewrite) | 8h | [satisfies REQ-001] | Validates: AC-001-1, AC-001-2, AC-001-3, AC-001-4, AC-001-5 | AC: Given a worker crashes and restarts, when restarted worker reconnects, then no duplicate work occurs (idempotency via aggregate version + command dedup); given worker unresponsive (no heartbeat for 60s), when timeout elapses, then run is marked `WorkerUnresponsive` and recovery is triggered
  - [ ] Rewrite of `Overwatch` using `Aggregate.Actor` + `CommandRouter` — not a port of `main`'s `worker_launcher.ex`
  - [ ] `Overwatch.Tracker` GenServer: tracks workers, manages liveness timers
  - [ ] `Overwatch.WorkerSupervisor`: `restart: :permanent`, strategy `:one_for_one`
  - [ ] `Overwatch.LaunchWorker`: spawns worker process, links to tracker
  - [ ] Emits `WorkerHeartbeat`, `WorkerExited`, `WorkerUnresponsive` through `CommandRouter`
  - [ ] On worker restart: idempotent via `command_id` (verify existing Actor deduplication covers this)
  - [ ] Heartbeat timeout: 60s (resolved per AC-001-5)
  - [ ] Orphan worker cleanup: detect via `DOWN` monitor

- [ ] **TRD-012** Crash loop detection | 4h | [satisfies REQ-002] | Validates: AC-002-1, AC-002-2 | AC: Given a worker restarts more than 3 times within a 5-minute window, when threshold is exceeded, then worker is marked `WorkerCrashed` and run is paused with clear error; given orphan worker (parent node gone), when `Overwatch` detects orphan, then worker is cleaned up and slot is released
  - [ ] `CrashLoopDetector` GenServer: tracks restart timestamps per worker
  - [ ] Window: 5 minutes, threshold: 3 restarts
  - [ ] On threshold exceeded: emit `WorkerCrashed`, pause run via `RunPaused` event
  - [ ] Orphan detection: `Process.monitor` on worker pid; on `DOWN` with `:noconnection` or parent death, release slot

- [x] **TRD-013** Worker environment isolation | 3h | [satisfies REQ-003] | Validates: AC-003-1, AC-003-2 | AC: Given a worker is launched, when it starts, then it receives a complete environment map from project's registered configuration; given config changes while worker is running, when new worker is launched for same run, then new config values take effect; config changes do not apply mid-run without worker restart
  - [x] `WorkerEnvironment` module: `build_env_map(project_id) :: map()`
  - [x] Sources config from project's registered configuration via `ProjectStore`
  - [x] Environment map passed to `LaunchWorker.spawn/3` as startup options
  - [x] No mid-run injection — worker reads env once at startup

---

### PR 4: Unified Ingestion + External Triggers + PR Lifecycle + Recovery + VCS
**Shippable State:** Webhook payloads are normalized and routed through Inbox.Poller; external triggers are polled when push webhooks are unavailable; PR associations sync via GitHub webhooks with polling fallback; recovery scanner detects interrupted runs and re-dispatches; VCS operations route through an abstraction with retry.

- [x] **TRD-014** Attach-bridge ingestion adapter | 3h | [satisfies REQ-007] | Validates: AC-007-1, AC-007-3 | AC: Given an attach-bridge webhook arrives, when it is received, then `AttachBridgeAdapter.normalize/1` transforms the payload into an `InboxItem`; specialized attach-bridge behaviour (streaming metadata, connection lifecycle) is preserved in the adapter before normalization; given a migration import is dispatched, when it is processed, then it routes through `CommandRouter` and appends migration events
  - [x] `AttachBridgeAdapter.normalize/1`: converts attach-bridge payload → `InboxItem`
  - [x] Preserves streaming metadata in adapter state before normalization
  - [x] `AttachBridgeAdapter.ingest/1`: calls `SharedInbox.ingest/2`
  - [x] Migration imports: `MigrationImporter.process/1` → `CommandRouter.dispatch/2`
  - [x] Dedup by correlation_id (from `SharedInbox` schema)

- [ ] **TRD-015** External trigger polling (pull fallback) | 3h | [satisfies REQ-008] | Validates: AC-008-1, AC-008-2 | AC: Given an external system cannot push webhooks, when a pull-based inbox poll is configured, then the poller periodically fetches pending triggers; given external trigger webhook arrives, when it is received, then it is routed to the appropriate handler and delivery status is tracked
  - [ ] `TriggerPoller` GenServer: configurable interval, calls external trigger endpoint
  - [ ] Fetches pending triggers, normalizes via `SharedInbox`
  - [ ] Delivery status tracked in projection store
  - [ ] Webhook ingestion same path: `TriggerWebhookController` → `SharedInbox.ingest/2`

- [x] **TRD-016** PR association | 2h | [satisfies REQ-009] | Validates: AC-009-1 | AC: Given a run completes, when operator provides PR URL or identity, then `PrAssociate.store/2` stores the association and emits `PrAssociated` through `CommandRouter`
  - [x] `PrAssociate` module: `store(run_id, pr_url) :: {:ok, pr_association_id}`
  - [x] Dispatches `PrAssociated` command through `CommandRouter`
  - [x] `PrAssociated` event: `%PrAssociated{run_id, pr_url, pr_number}`

- [x] **TRD-017** PR monitor + GitHub webhook | 5h | [satisfies REQ-009, REQ-010] | Validates: AC-009-2, AC-009-3, AC-010-1, AC-010-2 | AC: Given a PR is associated with a run, when GitHub sends webhook (opened/merged/closed/conflicted), then `Webhooks.Github.process/1` processes it and run projection reflects new PR state; if webhooks are missed/reordered, periodic polling fallback reconciles state every 5 minutes; given run is pending merge and PR status is not `open` and not `merged`, then PR gate actively blocks run progression
  - [x] `PrMonitor` GenServer: polls GitHub API every 5 minutes for associated PRs
  - [x] `Webhooks.Github` existing — verify it handles `pr_merged`, `pr_closed`, `pr reopened`, `pr_sync_conflict` events
  - [x] `PrGate` module: `check(run_id) :: :ok | {:error, :pr_not_acceptable}`
  - [x] `PrGate` blocks `Run` aggregate from transitioning to merge-pending if PR not open/merged
  - [x] Polling fallback: `PrMonitor.poll/0` every 5 minutes

- [x] **TRD-018** VCS adapter abstraction | 5h | [satisfies REQ-013] | Validates: AC-013-1, AC-013-2, AC-013-3 | AC: Given VCS operation is dispatched, when it fails transiently, then it retries up to 3 times with exponential backoff; non-transient failures (auth rejection, not found) are not retried; VCS adapter emits `VcsOperationStarted`, `VcsOperationCompleted`, or `VcsOperationFailed` through `CommandRouter`
  - [x] `VcsAdapter` behaviour: `clone/2`, `branch/2`, `create_pr/2`
  - [x] `VcsAdapter.Default` implementation (GitHub API)
  - [x] Retry: 3× exponential backoff; transient detection via error classification
  - [x] Events: `VcsOperationStarted`, `VcsOperationCompleted`, `VcsOperationFailed`
  - [x] All VCS operations route through `CommandRouter`

- [x] **TRD-019** Recovery scanner expansion | 4h | [satisfies REQ-011] | Validates: AC-011-1, AC-011-2, AC-011-3, AC-011-4 | AC: Given server restarts, when `Recovery` GenServer starts, then it scans `ProjectionStore` for interrupted runs and emits recovery events with explicit outcomes; given server restart with pending scheduled fire (intent recorded but pickup unconfirmed), when recovery runs, then fire is re-dispatched to new worker; idempotency preserved via aggregate version and command dedup
  - [x] Existing `Recovery` GenServer: expand `do_detect/0` to emit `RunRecoveryEvent` through `CommandRouter`
  - [x] `ScheduledFireRecorded` intent: on restart, `detect_unconfirmed_intents/0` finds pending intents
  - [x] `detect_unconfirmed_intents/0`: marks stale intents `SchedulerIntentStale`, re-dispatches
  - [x] Fire-and-track: `ScheduledFireConfirmed` on worker pickup; `ScheduledFireSkipped` if abandoned
  - [x] Idempotency: existing Actor command deduplication covers this (verify)

- [ ] **TRD-020** Stuck-run detection | 2h | [satisfies REQ-012] | Validates: AC-012-1 | AC: Given a run is active, when no phase or worker events have been appended for 15 minutes, then run is flagged `Stuck` in projection and alert is surfaced
  - [ ] `StuckDetector` GenServer: periodic scan, configurable via `:stuck_run_check_interval_seconds`
  - [ ] Scans active runs in `ProjectionStore`; checks `last_event_time`
  - [ ] 15-minute threshold (resolved per AC-012-1)
  - [ ] On stuck detection: emit `RunFlaggedStuck` event through `CommandRouter`
  - [ ] Alert surface: `Telemetry.execute([:foreman, :run, :stuck], %{run_id: run_id})`

- [ ] **TRD-021** Scheduler runtime | 5h | [satisfies REQ-011] | Validates: AC-011-3 | AC: Given a scheduled fire is due, when scheduler dispatches, then it records intent (`ScheduledFireRecorded`) and worker confirms on pickup (`ScheduledFireConfirmed`); no fire is lost if scheduler crashes between record and pickup
  - [ ] `Scheduler.Runtime` GenServer: fires scheduled tasks
  - [ ] `record_intent/2`: appends `ScheduledFireRecorded` event
  - [ ] Worker confirms via `confirm_execution/1`: appends `ScheduledFireConfirmed`
  - [ ] Crash between record and confirm: `Recovery.detect_unconfirmed_intents/0` re-dispatches

---

### PR 5: Configuration Parity + Workflow Templates
**Shippable State:** The application starts correctly in dev, test, and prod environments; workflow templates are bundled and installable via `foreman init`.

- [ ] **TRD-022** Config/dev.exs | 2h | [satisfies REQ-014] | Validates: AC-014-1 | AC: Given `config/dev.exs` is absent, when application starts in dev mode, then all required runtime configuration is present and loadable — EventStore, ProjectionStore, Phoenix endpoint, Overwatch
  - [ ] Import base `config.exs`
  - [ ] Dev EventStore: `localhost:55432`, verbose logging
  - [ ] Dev Repo: `localhost:55432/foreman_dev`
  - [ ] Phoenix dev endpoint: port 4766, `debug_errors: true`
  - [ ] Overwatch: enabled, verbose logging
  - [ ] Worker launcher: enabled

- [ ] **TRD-023** Config/test.exs | 1h | [satisfies REQ-014] | Validates: AC-014-2 | AC: Given `config/test.exs` is absent, when tests run, then test environment uses an appropriate test adapter (memory EventStore) and test-specific configuration
  - [ ] Import base `config.exs`
  - [ ] Test EventStore: memory adapter or `localhost:55432/foreman_test`
  - [ ] `worker_launcher_enabled: false` (already in `config.exs` — verify)
  - [ ] `Phoenix.Diagnostics` disabled
  - [ ] `Logster` capture disabled

- [ ] **TRD-024** Config/prod.exs | 2h | [satisfies REQ-014] | Validates: AC-014-3 | AC: Given `config/prod.exs` is absent, when application starts in prod mode, then production configuration is loadable; secrets sourced from secrets manager (Vault, AWS SM) in prod
  - [ ] Import base `config.exs`
  - [ ] EventStore URL from environment or secrets manager
  - [ ] Repo URL from environment or secrets manager
  - [ ] `Phoenix.endpoint` `server: true`, `debug_errors: false`
  - [ ] Secrets from `System.fetch_env!/1` or `Config.provider` for secrets manager
  - [ ] `灌 Security` note: Vault, AWS SM, or equivalent in prod; env vars in dev/test

- [ ] **TRD-025** Workflow YAML templates | 3h | [satisfies REQ-015] | Validates: AC-015-1, AC-015-2 | AC: Given `priv/defaults/workflows/` is absent, when `foreman init` runs, then the 6 standard workflow templates are installed; if bundled copy is unavailable, a fallback download from remote source is attempted; given a workflow template is missing a required phase, when interpreter loads it, then it fails fast with clear error
  - [ ] 6 templates: discover, assess, plan, implement, verify, release (or equivalents)
  - [ ] Each template: valid YAML, required phases defined
  - [ ] `WorkflowTemplate.Installer.install/1`: copies bundled templates to `~/.foreman/workflows/`
  - [ ] `WorkflowTemplate.Installer.fetch_remote/1`: fallback download (URL from app env)
  - [ ] `Workflow.Interpreter.load!/1`: raises on missing required phase

---

### PR 6: Debug Views + Operations Helpers
**Shippable State:** LiveView debug pages show real-time run/phase/worker state; operators can inspect and manipulate run state via CommandRouter-backed commands.

- [ ] **TRD-026** LiveView debug pages | 5h | [satisfies REQ-018] | Validates: AC-018-1 | AC: Given `debug_views.ex` is absent, when application runs in dev mode, then LiveView provides real-time interactive debug pages for run/phase/worker state diagnostics; LiveView is required (not optional)
  - [ ] `ForemanServerWeb.Debug.RunLive`: live view for run state
  - [ ] `ForemanServerWeb.Debug.PhaseLive`: live view for phase state
  - [ ] `ForemanServerWeb.Debug.WorkerLive`: live view for worker status
  - [ ] Phoenix Presence for real-time updates
  - [ ] Routes under `/debug/runs`, `/debug/phases`, `/debug/workers`
  - [ ] Dev-mode only (guard in router)

- [ ] **TRD-027** Operations helpers | 3h | [satisfies REQ-019] | Validates: AC-019-1 | AC: Given `operations.ex` is absent, when an operator needs to inspect or manipulate run state, then operations helpers are available through `CommandRouter`-backed commands — not direct state manipulation
  - [ ] `Operations.Inspect.run_state/1`: reads from `ProjectionStore`
  - [ ] `Operations.Manual.mark_recovered/1`: dispatches `RecoveryDetected` through `CommandRouter`
  - [ ] `Operations.Manual.force_complete/1`: dispatches `CompleteRun` through `CommandRouter`
  - [ ] `Operations.Inspect.list_active_runs/0`: returns list from `ProjectionStore`
  - [ ] All ops route through `CommandRouter` — no direct state reads/writes

---

### PR 7: Test Parity + NFR Implementation
**Shippable State:** All absent domain modules have corresponding test coverage; telemetry events fire on command dispatch and aggregate rehydration; hard run limit (100 per project) is enforced at the aggregate level.
- [ ] **TRD-040** Telemetry event emission | 3h | [satisfies REQ-023] | Validates: AC-023-1, AC-023-2 | AC: Given a command is dispatched through `CommandRouter`, when the command is processed, then `[:foreman, :command, :dispatch]` telemetry event is emitted with `duration_ms`, `append_latency_ms`, `status`, and `aggregate_id`; given an aggregate `Actor` restarts and completes rehydration via `Aggregate.load/2`, when rehydration finishes, then `[:foreman, :aggregate, :rehydrated]` telemetry event is emitted with `event_count`; `[:foreman, :run, :stuck]` fires when stuck run detected; `[:foreman, :worker, :heartbeat]` and `[:foreman, :worker, :exit]` fire on worker lifecycle transitions
  - [ ] Emit in `CommandRouter.dispatch/1`: `duration_ms`, `append_latency_ms`, `status`, `aggregate_id`
  - [ ] Emit in `Aggregate.Actor` after `Aggregate.load/2` completes: `[:foreman, :aggregate, :rehydrated]` with `event_count`
  - [ ] Emit in stuck-run detector: `[:foreman, :run, :stuck]` with `run_id`
  - [ ] Emit in overwatch: `[:foreman, :worker, :heartbeat]` and `[:foreman, :worker, :exit]`
  - [ ] All events use OpenTelemetry semantic conventions where applicable

- [ ] **TRD-041** Event store durability + scale limit enforcement | 3h | [satisfies REQ-021, REQ-022] | Validates: AC-021-1, AC-021-2, AC-021-3, AC-022-1, AC-022-2 | AC: Given Postgres is initialized, when the database is created, then `data_checksums = on` and `wal_level = replica` are enabled; given a project has 100 active runs, when `StartRun` is dispatched, then `:run_limit_exceeded` is returned before `RunStarted` is appended; given a stream gap is detected, when projected count differs from expected, then `StreamGapDetected` event surfaces an alert and `CommandRouter` refuses any further appends to the affected stream until the gap is resolved
  - [ ] Postgres init script / migration: `data_checksums = on`, `wal_level = replica`
  - [ ] **Run limit (REQ-022):** `CommandRouter` routes `StartRun` through the **project-level owner** (either `Project` aggregate or a dedicated `ProjectRunLimit` aggregate) that atomically increments and checks `active_run_count` before emitting `RunStarted` — **never** a projection lookup inside `Run.handle_command`
  - [ ] `StreamGapDetector`: projection version vs. stream version; emit `StreamGapDetected` on mismatch; `CommandRouter` consults this detector before each append and refuses appends for flagged streams

- [x] **TRD-011-TEST** Overwatch test coverage | 4h | [verifies TRD-011] [depends: TRD-011, TRD-012] [satisfies REQ-020, REQ-001, REQ-002] | Validates: AC-001-1–AC-001-5, AC-002-1, AC-002-2, AC-020-2, AC-020-5 | Implementation AC: Given worker lifecycle events are emitted, when `Overwatch` is tested in isolation, then `WorkerHeartbeat` and `WorkerExited` events are routed through `CommandRouter` and the run projection reflects the correct state; AC1 (supervised actor) and AC2 (idempotency) tests pass
  - [x] Test: `start_phase/2` → full `WorkerStarted` event appended (session_id, adapter, prompt_path, tool_names, artifact_paths); `WorkerProtocol.emit/2` via `Tracker` → `WorkerHeartbeat/Exited/Unresponsive` through `CommandRouter`
  - [x] Test: heartbeat timeout (60s) → `WorkerUnresponsive` event
  - [x] Test: crash loop (3 restarts/5 min) → `WorkerCrashed` + run paused
  - [x] Test: worker restart → no duplicate work (command dedup)
  - [x] Test: orphan worker → slot released
  - [x] AC1: supervised actor survives restart (link to `ac1_aggregate_actor_test.exs`)
  - [x] AC2: idempotent duplicate command (link to `ac2_duplicate_out_of_order_test.exs`)

- [x] **TRD-013-TEST** Worker environment isolation test | 2h | [verifies TRD-013] [satisfies REQ-003] | Validates: AC-003-1, AC-003-2 | Implementation AC: Given a worker is launched, when it starts, then it receives the complete environment map from the project's registered configuration; given config changes while worker is running, when a new worker is launched for same run, then new config values take effect; mid-run config changes do not apply without restart
  - [x] Test: `WorkerEnvironment.build_env_map/1` returns a complete map for a registered project
  - [x] Test: env map contains no leakage from other workers
  - [x] Test: changed project config takes effect on next worker launch for same run

- [ ] **TRD-019-TEST** Recovery scanner + stuck-run test coverage | 3h | [verifies TRD-019, TRD-020, TRD-021] [depends: TRD-019, TRD-020, TRD-021] [satisfies REQ-011, REQ-012, REQ-020] | Validates: AC-011-1–AC-011-4, AC-012-1, AC-020-3, AC-020-5 | Implementation AC: Given recovery scanner runs on startup, when interrupted runs are detected, then `RecoveryDetected` events are emitted through `CommandRouter` and runs resume idempotently; stuck run (15 min inactive) surfaces `RunFlaggedStuck` and telemetry
  - [ ] Test: startup scan → `RunRecoveryEvent` for interrupted run
  - [ ] Test: duplicate recovery dispatch → idempotent (existing AC2 covers this)
  - [ ] Test: `detect_unconfirmed_intents/0` → stale intent re-dispatched
  - [ ] Test: stuck run (15 min inactive) → `RunFlaggedStuck` event + `[:foreman, :run, :stuck]` telemetry
  - [ ] Test: fire-and-track — intent recorded, worker confirms, no fire lost on scheduler crash
  - [ ] Expand existing `recovery_test.exs`

- [ ] **TRD-009-TEST** Run aggregate test coverage | 4h | [verifies TRD-009] [depends: TRD-009] [satisfies REQ-004, REQ-020] | Validates: AC-004-1–AC-004-4 | Implementation AC: Given `CompleteRun` on a terminal run, when dispatched, then `RunAlreadyCompleted` event appended and state unchanged; given run aggregate restarts, when `Aggregate.load/2` called, then correct terminal/non-terminal state restored; AC1 and AC2 tests green
  - [ ] Test: `StartRun` → initial state `{:active, terminal?: false}`
  - [ ] Test: `CompleteRun` on active run → `RunCompleted`, `terminal?: true`
  - [ ] Test: `CompleteRun` on already-completed run → `RunAlreadyCompleted`, state unchanged
  - [ ] Test: stream replay → correct terminal/non-terminal state
  - [ ] Test: optimistic concurrency conflict → `{:error, :wrong_expected_version}`

- [x] **TRD-008-TEST** Phase aggregate test coverage | 3h | [verifies TRD-008] [depends: TRD-008] [satisfies REQ-005, REQ-020] | Validates: AC-005-1–AC-005-3 | Implementation AC: Given two `CompletePhase` commands race, when the second append uses the wrong expected version, then append fails with concurrency conflict and the actor retries with the correct version
  - [x] Test: `StartPhase` → `PhaseStarted`, state transitions to active
  - [x] Test: `CompletePhase` → `PhaseCompleted`, state terminal
  - [x] Test: concurrent `CompletePhase` → concurrency conflict → retry
  - [x] Test: `FailPhase`, `SkipPhase` transitions

- [ ] **TRD-010-TEST** BoardItemStateMachine test coverage | 2h | [verifies TRD-010] [depends: TRD-010] [satisfies REQ-006, REQ-020] | Validates: AC-006-1, AC-006-2 | Implementation AC: Given invalid status transition (e.g., `closed` → `in_progress`), when the command is dispatched, then `{:error, :invalid_transition}` returned
  - [ ] Test: valid transitions: backlog → in_progress → in_review → done
  - [ ] Test: invalid transition → `{:error, :invalid_transition}`
  - [ ] Test: terminal state (done) rejects further transitions

- [ ] **TRD-033-TEST** Unified ingestion + external trigger test coverage | 3h | [verifies TRD-001, TRD-006, TRD-014, TRD-015] [depends: TRD-001, TRD-006, TRD-014, TRD-015] [satisfies REQ-007, REQ-008, REQ-020] | Validates: AC-007-1–AC-007-4, AC-008-1, AC-008-2 | Implementation AC: Given duplicate ingestion event arrives, when the dedupe window is checked, then the duplicate is rejected and delivery status tracked; given pull-based poll is configured, when external system cannot push, then the poller periodically fetches pending triggers
  - [ ] Test: attach-bridge webhook → normalized `InboxItem` → deduplicated
  - [ ] Test: integration ingestion webhook → routed through `Inbox.Poller`
  - [ ] Test: migration import → `CommandRouter` → `MigrationImportStarted`
  - [ ] Test: dedupe hit → `InboxItemDeduped`, no re-processing
  - [ ] Test: `TriggerPoller` periodic fetch
  - [ ] Test: trigger webhook delivery status tracked

- [ ] **TRD-034-TEST** PR lifecycle test coverage | 3h | [verifies TRD-016, TRD-017] [depends: TRD-016, TRD-017] [satisfies REQ-009, REQ-010, REQ-020] | Validates: AC-009-1–AC-009-3, AC-010-1, AC-010-2 | Implementation AC: Given run is pending merge and PR status is not `open` and not `merged`, then the PR gate actively blocks run progression; polling fallback reconciles PR state every 5 minutes
  - [ ] Test: `PrAssociated` event appended on PR URL provided
  - [ ] Test: GitHub webhook → `PrStateChanged` → projection updated
  - [ ] Test: polling fallback reconciles PR state every 5 minutes
  - [ ] Test: PR not open/merged → `PrGate.check/1` returns `{:error, :pr_not_acceptable}`
  - [ ] Test: `PrGate` blocks run from transitioning to merge-pending

- [ ] **TRD-035-TEST** VCS adapter test coverage | 2h | [verifies TRD-018] [depends: TRD-018] [satisfies REQ-013, REQ-020] | Validates: AC-013-1–AC-013-3 | Implementation AC: Given VCS operation fails transiently, when retried, then 3 retries with exponential backoff occur; non-transient failures are not retried; events are emitted through `CommandRouter`
  - [ ] Test: transient failure → 3 retries with exponential backoff
  - [ ] Test: non-transient failure → no retry, `VcsOperationFailed`
  - [ ] Test: success → `VcsOperationCompleted`
  - [ ] Test: `VcsOperationStarted` event emitted before operation

- [ ] **TRD-036-TEST** Project infrastructure test coverage | 3h | [verifies TRD-002, TRD-003, TRD-004, TRD-005] [depends: TRD-002, TRD-003, TRD-004, TRD-005] [satisfies REQ-016, REQ-020] | Validates: AC-016-1–AC-016-3 | Implementation AC: Given `ProjectRegistry` is implemented, when a project process registers, then `ProjectRegistry` maintains the name-to-pid mapping and `ProjectSupervisor` restarts crashed processes; project config is persisted via event store and read via `ProjectionStore`
  - [ ] Test: project registered → `ProjectRegistered` event appended
  - [ ] Test: project process crash → `ProjectSupervisor` restarts it
  - [ ] Test: `ProjectRegistry` lookup returns correct pid
  - [ ] Test: project config persisted via event store, read via `ProjectionStore`

- [ ] **TRD-037-TEST** Config parity test coverage | 2h | [verifies TRD-022, TRD-023, TRD-024] [depends: TRD-022, TRD-023, TRD-024] [satisfies REQ-014, REQ-020] | Validates: AC-014-1–AC-014-3 | Implementation AC: Given dev, test, and prod configs exist, when the application starts in each environment, then the correct configuration is loaded; in prod, secrets are sourced from a secrets manager
  - [ ] Test: dev config loads without errors
  - [ ] Test: test config uses memory EventStore adapter
  - [ ] Test: prod config uses `Config.provider` for secrets manager
  - [ ] Test: missing required secret raises on startup

- [ ] **TRD-007-TEST** PlanningFlow test coverage | 2h | [verifies TRD-007] [depends: TRD-007] [satisfies REQ-017] | Validates: AC-017-1, AC-017-2 | Implementation AC: Given `plan.prd` or `plan.trd` command is dispatched, when `PlanningFlow` processes it, then `PlanningFlowStarted` event is appended; trace events append through the existing aggregate infrastructure
  - [ ] Test: `plan.prd` command → `PlanningFlowStarted` event appended
  - [ ] Test: trace events append through aggregate infrastructure
  - [ ] Test: `plan.trd` command → same routing

- [ ] **TRD-025-TEST** Workflow template test coverage | 2h | [verifies TRD-025] [depends: TRD-025] [satisfies REQ-015] | Validates: AC-015-1, AC-015-2 | Implementation AC: Given `priv/defaults/workflows/` is absent, when `foreman init` runs, then 6 standard workflow templates are installed from the bundle; if the bundled copy is unavailable, a fallback download is attempted; given a template is missing a required phase, when the interpreter loads it, then it raises with a clear error
  - [ ] Test: `foreman init` installs 6 templates from bundle
  - [ ] Test: bundle unavailable → fallback download attempted
  - [ ] Test: missing required phase → `Workflow.Interpreter.load!/1` raises

- [ ] **TRD-026-TEST** LiveView debug pages test coverage | 2h | [verifies TRD-026] [depends: TRD-026] [satisfies REQ-018] | Validates: AC-018-1 | Implementation AC: Given `debug_views.ex` is absent, when the application runs in dev mode, then LiveView provides real-time interactive debug pages; Phoenix Presence updates are reflected in the UI within 1 second
  - [ ] Test: `/debug/runs` page renders active run state
  - [ ] Test: `/debug/phases` page renders phase state
  - [ ] Test: `/debug/workers` page reflects worker liveness
  - [ ] Test: Phoenix Presence updates appear within 1 second

- [ ] **TRD-027-TEST** Operations helpers test coverage | 2h | [verifies TRD-027] [depends: TRD-027] [satisfies REQ-019] | Validates: AC-019-1 | Implementation AC: Given `operations.ex` is absent, when an operator uses operations helpers, then all operations route through `CommandRouter` — no direct state reads or writes
  - [ ] Test: `Operations.Inspect.run_state/1` reads from `ProjectionStore`
  - [ ] Test: `Operations.Manual.mark_recovered/1` dispatches `RecoveryDetected` through `CommandRouter`
  - [ ] Test: `Operations.Manual.force_complete/1` dispatches `CompleteRun` through `CommandRouter`
  - [ ] Test: `Operations.Inspect.list_active_runs/0` returns list from `ProjectionStore`

- [ ] **TRD-040-TEST** Telemetry events test | 3h | [verifies TRD-040] [depends: TRD-040] [satisfies REQ-023] | Validates: AC-023-1, AC-023-2 | Implementation AC: Given a command is dispatched, when processed, then `[:foreman, :command, :dispatch]` telemetry event is emitted with `duration_ms`, `append_latency_ms`, `status`; given an aggregate actor restarts and rehydrates, when rehydration completes, then `[:foreman, :aggregate, :rehydrated]` event is emitted with `event_count`
  - [ ] Test: `[:foreman, :command, :dispatch]` emitted on command dispatch with correct fields
  - [ ] Test: `[:foreman, :aggregate, :rehydrated]` emitted after actor restart with `event_count`
  - [ ] Test: `[:foreman, :run, :stuck]` emitted when stuck run detected
  - [ ] Test: `[:foreman, :worker, :heartbeat]` and `[:foreman, :worker, :exit]` emitted on worker lifecycle events

- [ ] **TRD-041-TEST** Event store durability + scale limits test | 3h | [verifies TRD-041] [depends: TRD-041] [satisfies REQ-021, REQ-022] | Validates: AC-021-1, AC-021-2, AC-021-3, AC-022-1, AC-022-2 | Implementation AC: Given Postgres is initialized, when the database is created, then `data_checksums = on` and `wal_level = replica` are enabled; given silent data loss occurs and gap is detected, when the gap is detected, then `StreamGapDetected` event surfaces an alert and further appends to the affected stream are blocked until the gap is resolved; given a project has 100 active runs, when `StartRun` is dispatched, then the aggregate returns `:run_limit_exceeded` before any event is appended
  - [ ] Test: Postgres init includes `data_checksums = on` (setup script or migration)
  - [ ] Test: `StreamGapDetected` event surfaces alert when projected count < expected
  - [ ] Test: gap blocks further appends to affected stream (raises or returns error)
  - [ ] Test: 100th active run → `StartRun` rejected with `:run_limit_exceeded` before any event appended
  - [ ] Test: limit enforced at aggregate level (checked in `handle_command`, not in caller)
---
## Team Configuration

> **Complexity Metrics** (auto-injected by ensemble:configure-team)
> - task_count: 29 implementation + 17 test = **46 total**
> - estimated_hours: 103h implementation + 45h test = **148h total**
> - domain_count: 10
> - domains: devops, elixir_cqrs, frontend, observability, otp, phoenix, planning, postgres, testing, vcs
> - cross_cutting: 10
> - dependency_depth: 1
> - tier: Complex
>
> **⚠ Discovery warning:** No agent registry (`packages/*/agents/*.yaml`), skills directories (`**/skills/`), marketplace (`marketplace.json`), or router rules (`.claude/router-rules.json`) were found. All agent assignments below are default/fallback assignments based on domain-keyword heuristics — they have **not** been validated against a live registry. Review and replace role names with actual discovered agents before implementation.

```yaml
team:
  roles:
    - name: lead
      agent: tech-lead-orchestrator
      owns: [task-selection, architecture-review, final-approval]
    - name: builder
      agents:
        - backend-developer  # tasks: TRD-001–TRD-021; domains: elixir_cqrs, otp, postgres, phoenix, vcs
        - frontend-developer  # tasks: TRD-026; domains: phoenix, frontend
        - infrastructure-developer  # tasks: TRD-022–TRD-024; domains: devops, postgres
        - release-agent  # tasks: TRD-025, TRD-027, TRD-040, TRD-041; domains: observability, planning
        - qa-orchestrator  # tasks: TRD-011-TEST, TRD-013-TEST, TRD-019-TEST, TRD-009-TEST, TRD-008-TEST, TRD-010-TEST, TRD-033-TEST, TRD-034-TEST, TRD-035-TEST, TRD-036-TEST, TRD-037-TEST, TRD-007-TEST, TRD-025-TEST, TRD-026-TEST, TRD-027-TEST, TRD-040-TEST, TRD-041-TEST; domains: testing
      owns: [implementation, test-execution]
    - name: reviewer
      agent: code-reviewer
      owns: [pull-request-review, architecture-gate]
    - name: qa
      agent: qa-orchestrator
      owns: [test-planning, test-execution, quality-sign-off]
```

## Sprint Planning

> **Informational only.** Groups tasks by calendar sprint for time-boxing. Implementers use the Master Task List (above) as the authoritative task reference — implement-trd-beads parses the `### PR N:` sections, not this section.

### Sprint 1: Foundation
**Goal:** Project registry, store, supervisor, and shared inbox schema land. No downstream work is blocked after this sprint.

- TRD-001 — SharedInbox schema
- TRD-002 — ProjectRegistry
- TRD-003 — ProjectSupervisor
- TRD-004 — ProjectStore
- TRD-005 — Project aggregate
- TRD-006 — Integration ingestion
- TRD-007 — PlanningFlow aggregate


### Sprint 2: Core Aggregates
**Goal:** Run and Phase aggregates ship; board item state transitions enforced.

- TRD-008 — Phase aggregate
- TRD-009 — Run aggregate
- TRD-010 — BoardItemStateMachine

### Sprint 3: Worker Runtime
**Goal:** Overwatch rewrite ships; workers supervised and recoverable.

- TRD-011 — Overwatch worker runtime
- TRD-012 — Crash loop detection
- TRD-013 — Worker environment isolation


### Sprint 4: Ingestion + PR Lifecycle + Recovery
**Goal:** All external integrations — ingestion, PR sync, recovery — ship together.

- TRD-014 — Attach-bridge adapter
- TRD-015 — Trigger poller
- TRD-016 — PR association
- TRD-017 — PR monitor + gate
- TRD-018 — VCS adapter
- TRD-019 — Recovery scanner expansion
- TRD-020 — Stuck detector
- TRD-021 — Scheduler runtime


### Sprint 5: Config + Templates
**Goal:** Application starts correctly in all three environments; workflow templates bundled.

- TRD-022 — Config/dev.exs
- TRD-023 — Config/test.exs
- TRD-024 — Config/prod.exs
- TRD-025 — Workflow templates


### Sprint 6: Debug + Ops
**Goal:** LiveView debug pages and operations helpers ship.

- TRD-026 — LiveView debug pages
- TRD-027 — Operations helpers

### Sprint 7: Test Parity + NFRs
**Goal:** All 17 test parity tasks implemented; telemetry and scale limits enforced.

**Implementation tasks:**
- TRD-040 — Telemetry event emission
- TRD-041 — Event store durability + scale limit enforcement

**Test tasks:** TRD-011-TEST, TRD-013-TEST, TRD-019-TEST, TRD-009-TEST, TRD-008-TEST, TRD-010-TEST, TRD-033-TEST, TRD-034-TEST, TRD-035-TEST, TRD-036-TEST, TRD-037-TEST, TRD-007-TEST, TRD-025-TEST, TRD-026-TEST, TRD-027-TEST, TRD-040-TEST, TRD-041-TEST

---

## Acceptance Criteria Traceability

| REQ | Description | Priority | Implementation Tasks | Test Tasks |
|---|---|---|---|---|
| REQ-001 | Worker runtime (fresh rewrite) | Must | TRD-011 | TRD-011-TEST |
| REQ-002 | Crash loop detection | Must | TRD-012 | TRD-011-TEST |
| REQ-003 | Worker environment isolation | Should | TRD-013 | TRD-013-TEST |
| REQ-004 | Run state-machine aggregate | Must | TRD-009 | TRD-009-TEST |
| REQ-005 | Phase state-machine aggregate | Must | TRD-008 | TRD-008-TEST |
| REQ-006 | Board item state machine | Must | TRD-010 | TRD-010-TEST |
| REQ-007 | Unified ingestion (consolidate 3 paths) | Must | TRD-001 (schema), TRD-006, TRD-014 | TRD-033-TEST |
| REQ-008 | External trigger ingestion | Should | TRD-001 (schema), TRD-015 | TRD-033-TEST |
| REQ-009 | PR association + GitHub webhook sync | Must | TRD-016, TRD-017 | TRD-034-TEST |
| REQ-010 | PR gate enforcement | Should | TRD-017 | TRD-034-TEST |
| REQ-011 | Recovery scanner + fire-and-track scheduler | Must | TRD-019, TRD-021 | TRD-019-TEST |
| REQ-012 | Stuck-run detection | Should | TRD-020 | TRD-019-TEST |
| REQ-013 | VCS adapter abstraction | Must | TRD-018 | TRD-035-TEST |
| REQ-014 | Environment configuration parity | Must | TRD-022, TRD-023, TRD-024 | TRD-037-TEST |
| REQ-015 | Workflow template parity | Should | TRD-025 | TRD-025-TEST |
| REQ-016 | Project registry, store, supervisor | Must | TRD-002, TRD-003, TRD-004, TRD-005 | TRD-036-TEST |
| REQ-017 | Planning flow coordinator | Should | TRD-007 | TRD-007-TEST |
| REQ-018 | LiveView debug pages | Should | TRD-026 | TRD-026-TEST |
| REQ-019 | Operations helpers | Should | TRD-027 | TRD-027-TEST |
| REQ-020 | Test suite parity (35 files; 17 tracked test tasks) | Must | all TRD-*-TEST implementation files | N/A (meta requirement — see Sprint 7) |
| REQ-021 | Event store durability + gap detection | Must | TRD-041 | TRD-041-TEST |
| REQ-022 | Scale limit enforcement | Must | TRD-041 | TRD-041-TEST |
| REQ-023 | Observability (telemetry) | Could | TRD-040 | TRD-040-TEST |

---

## Quality Requirements

### Security
- Secrets in prod: `Vault`, `AWS Secrets Manager`, or equivalent. Env vars only in dev/test.
- Worker processes are isolated — no environment leakage between workers (REQ-003).
- No direct event store access outside `CommandRouter` — enforced by architecture test.

### Performance
- Run limit: 100 concurrent active runs per project — enforced at aggregate level (REQ-022).
- Stuck-run detection: 15-minute threshold (REQ-012).
- PR polling fallback: 5-minute interval (REQ-009 AC-009-3).
- VCS retry: 3× exponential backoff for transient failures only (REQ-013 AC-013-2).

### Testing Standards
- All 17 test parity tasks implemented (REQ-020).
- AC1 (supervised actor) and AC2 (idempotency) tests must remain green (AC-020-5).
- Architecture test `event_store_enforcement_test.exs` expanded to cover new modules.

### Durability
- Postgres `data_checksums = on`, `wal_level = replica` (REQ-021).
- Silent data loss: gap detection + alert + append block (AC-021-3).
- Crash loop detection: 3 restarts within 5 minutes → run paused (REQ-002).

---

## Design Readiness Scorecard

| Dimension | Score (1–5) | Notes |
|---|---|---|
| Architecture completeness | 4 | All implementation tasks mapped (29 impl + 17 test tasks); interfaces defined; data flows specified; cycle in REQ-007/008 resolved via shared schema |
| Task coverage | 4 | Every non-meta REQ has ≥1 implementation task + test task; REQ-020 (meta) covered by the 17 tracked test tasks |
| Dependency clarity | 4 | Dependency graph is acyclic; cycle broken; critical path identified; PR boundaries respect dependency order |
| Estimate confidence | 4 | Estimates range 1–8h; no individual task >8h (all within threshold); similar tasks have consistent estimates |

**Overall: 4.0 — PASS**

### Architecture Issues Identified and Resolved

1. **REQ-007/REQ-008 cycle**: The PRD shows mutual dependency. Resolution: TRD-001 (SharedInbox schema) is the common dependency — both ingestion and external trigger polling depend on it, not on each other. The cycle is broken at the schema layer.

2. **BoardItemStateMachine depends on Phase**: BoardItem transitions may involve phase context. Resolution: Both Phase and BoardItemStateMachine are in PR2; Phase task is ordered before BoardItemStateMachine — Phase ships first.


### Dependency Issues

- **Critical path depth**: TRD-001 (2h) → TRD-008 (5h) → TRD-009 (6h) → TRD-011 (8h) → TRD-019 (4h) → TRD-020 (2h). Total: 27h of sequential work on critical path across 5 sprints.

### Testability Issues

- **AC-021-3** ("system alerts operators and prevents further appends to the affected stream until the gap is resolved"): This is a manual operational procedure, not a unit-testable assertion. Recommend: test the alert emission and append-block at the unit level; end-to-end gap-resolve procedure is verified by integration test or runbook.

---

*Generated: 2026-07-29 | Document ID: TRD-2026-7b4a3944 | Source PRD: PRD-2026-7b4a3944 (v1.0.1) | Design Readiness: 4.0 PASS*
