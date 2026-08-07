---
document_id: TRD-2026-002184c6
label: trd-projects-crud
prd_reference: PRD-2026-002184c6
version: 1.0.4
status: Draft
date: 2026-08-07
kind: trd
scale_depth: STANDARD
design_readiness_score: 3.4
ensemble_implement_trd_beads:
  branch_name: slices/go-elixir-cqrs
  use_proposed: false
  stacked_prs: false
---

# TRD: Project CRUD — HTTP Resource Read + Command-Gateway Mutations

> **Source PRD:** [PRD-2026-002184c6-projects-crud.md](../PRD/PRD-2026-002184c6-projects-crud.md) v0.1.4
> **Architecture choice:** Option A — In-process Phoenix controller (see §2a)
> **Open ambiguities at TRD stage:** AMB-001, AMB-003, AMB-004, AMB-005 (resolved in §3)

---

## 1. PRD Snapshot

| Item | Value |
|---|---|
| Title | Project CRUD — HTTP Resource Read + Command-Gateway Mutations |
| Scale | STANDARD |
| Total requirements | 17 (Must 12, Should 4, Could 1, Won't 0) |
| Total ACs | 78 |
| PRD readiness score | 3.5 — TENTATIVE (4 open AMBs; none block PRD-to-TRD progression per user approval 2026-08-07) |
| Open AMBs at TRD stage | AMB-001 (numeric adoption target), AMB-003 (p99 latency), AMB-004 (active-run definition), AMB-005 (list hard cap) |
| Capabilities reused from foundational TRDs | None (capability registry empty; `trd-graph-cli overlap` reports no target-file overlap) |

---

## 2. Architecture Decision

### 2a. Alternatives considered

| Option | Approach | Verdict |
|---|---|---|
| **A** | In-process Phoenix `ProjectController`; mutations via existing `CommandGateway.dispatch_operator/2`; Go CLI subcommand grouping; web-layer CQRS test mirrors `event_store_enforcement_test.exs` | **Selected** — minimal new surface; matches existing `task`/`run` resource-route pattern; zero new infrastructure |
| B | Action-based JSON-RPC façade (`POST /api/projects` with `action` field) | Rejected — breaks existing CLI conventions; harder to cache; deviates from `AGENTS.md` spirit |
| C | Separate "projects-api" Phoenix sub-app | Rejected — violates "no new infrastructure" from `AGENTS.md`; doubles Bearer-plug/pipeline surface |

### 2b. System architecture (Option A)

```mermaid
flowchart TB
    subgraph GoCLI["foreman CLI (packages/foreman_cli)"]
        Create["foreman project create"]
        Get["foreman project get"]
        Update["foreman project update"]
        Delete["foreman project delete"]
        List["foreman project list"]
    end
    subgraph Phoenix["foreman_server_web (Phoenix)"]
        Router["router.ex<br/>+ 2 new GET routes"]
        PC["ProjectController<br/>(new)"]
        CC["CommandController<br/>(allowlist updated)"]
    end
    subgraph Core["foreman_server"]
        CG["CommandGateway<br/>(allowlist + identity validator)"]
        CR["CommandRouter<br/>(router-owned admission path;<br/>private do_dispatch/2)"]
        DISP["Workflow Dispatcher<br/>(existing; only caller of run.start)"]
        RA["RunAdmission (new)<br/>thin delegate over<br/>CommandRouter.dispatch_run_start/2"]
        RLR["RunLifecycleReconciler (new)<br/>sub + scheduled pass;<br/>retry-not-release for orphans"]
        PAct["Project aggregate actor<br/>(extended: active_run_reservations map)"]
        RAct["Run aggregate actor<br/>(extended: project_id field)"]
        PS["project_store<br/>(read for list)"]
        PrS["ProjectionStore<br/>(list_projects_with_active_runs/0<br/>enumeration only — never for<br/>safety decisions)"]
    end
    subgraph ES["EventStore (existing)"]
        Events[("foreman_events<br/>+ projection store")]
    end
    Create --> CC
    Update --> CC
    Delete --> CC
    Get --> Router
    List --> Router
    Router --> PC
    PC --> PS
    CC --> CG
    CG --> CR
    CR --> PAct
    CR --> RAct
    PAct --> Events
    RAct --> Events
    PS --> Events
    DISP --> RA
    RA -->|step 1: project.reserve_run| CR
    RA -->|step 2: run.start<br/>(deterministic command_id<br/>from reservation)| CR
    RA -->|on definitive rejection only:<br/>project.release_run_reservation| CR
    Events -->|terminal events<br/>(carry project_id + run_id)| RLR
    RLR -->|terminal-event release:<br/>project.release_run_reservation| CR
    RLR -->|scheduled-pass orphan recovery:<br/>RunAdmission.start(recovered_payload)| RA

    classDef new fill:#fff4e1,stroke:#d68500,stroke-width:2px
    class RA,RLR new
```

**Data flow:**

- **Read (`GET /api/projects/:id`):** Phoenix router → `ProjectController.show/2` → `project_store.get/1` (no event appended, no command dispatched).
- **Read (`GET /api/projects`):** Phoenix router → `ProjectController.index/2` → `project_store.list/0` (filtered by `include_archived?`; capped by `projects_list_max` config, default 1000). **`X-Total-Count` exposes the underlying full count of matching rows** (NOT the truncated body length); the body itself is capped at the configured limit and signals truncation via `meta.truncated: true`.
- **Mutation (`POST /api/commands` with `project.update` / `project.archive`):** Phoenix router → `CommandController.create/2` → `CommandGateway.dispatch_operator/2` → identity validator (`validate_aggregate_id/1` for the new types) → `CommandRouter` → aggregate actor → event store.
- **Run start (workflow dispatcher):** `Workflow.Dispatcher` → `RunAdmission.start/2` → step 1: `project.reserve_run` → step 2: `run.start` (deterministic `command_id` derived from the reservation, NO `admission:` sentinel — v1.0.1 removed it) → both dispatched via `CommandRouter.dispatch_run_start/2` → `defp do_dispatch/2` → respective aggregate actors → event store. **Compensation policy (definitive-rejection allowlist):** only `:phase_terminal` and `:run_already_terminal` failures at step 2 trigger `project.release_run_reservation` (step 3). All other failures (timeout, crash, transient) RETAIN the reservation; the reconciler scheduled pass retries `RunAdmission.start(recovered_payload)` with the deterministic `command_id` from `Project.State.active_run_reservations[run_id]` (actor-level event dedup absorbs concurrent retries). The reservation is never released on absence alone — that would race a successful `run.start` and orphan the run.
- **Reconciler (two access paths, one authoritative source):**
  - **Subscription path (sub-second happy path):** `RunLifecycleReconciler` subscribes to `RunCompleted`, `RunFailed`, `RunCancelled`, `RunBlocked`, `RunFlaggedStuck` → reads `project_id` + `run_id` directly from the terminal event payload (no `ProjectionStore.run_projection/1` — terminal events carry `project_id`) → dispatches `project.release_run_reservation`.
  - **Scheduled path (60s crash recovery):** enumerates candidates via `ProjectionStore.list_projects_with_active_runs/0` → loads authoritative state via `Project.load(project_id)` (for the reservation metadata to re-dispatch) and `Run.load(run_id)` (to confirm the run is truly absent vs. just unsubscribed) → if `Run.State.exists? == false`, retries `RunAdmission.start(recovered_payload)` with the deterministic `command_id` from the reservation. Never reads `project_id` from `ProjectionStore.run_projection/1`.

**Single mutation surface:** `POST /api/commands` (per `AGENTS.md`). Two new resource routes only (`GET /api/projects/:id`, `GET /api/projects`). All `run.start` dispatch flows through `RunAdmission` (the gateway allowlist does NOT include `run.start`; CLI/HTTP cannot bypass).


### 2c. Component responsibilities

| Component | Responsibility | New? |
|---|---|---|
| `foreman_server_web/router.ex` | Route two new GETs through the existing `:api` pipeline (Bearer plug) | Modify (add 2 routes) |
| `foreman_server_web/controllers/project_controller.ex` | `show/2` and `index/2` actions; reads from `project_store`; emits `[:foreman_server, :project, :read]` and `[:foreman_server, :project, :list]` telemetry | New |
| `foreman_server_web/controllers/command_controller.ex` | Allow `project.update` and `project.archive` in `@allowed_types`, `aggregate_prefix/1`, `id_field_for/1` | Modify (3 tables) |
| `foreman_server/command_gateway.ex` | Add `project.update` and `project.archive` to `@allowed_operator_types`; add `validate_aggregate_id/1` clauses for both | Modify (2 surfaces) |
| `foreman_server/command_router.ex` | Three-function API: `dispatch/2` (public, rejects `type: "run.start"` with `ArgumentError` naming `RunAdmission.start/2`), `dispatch_run_start/2` (public, owns the entire multi-step protocol via the private `do_dispatch/2`), and `do_dispatch/2` (`defp` private, the actual append primitive). No sentinel field/atom — `defp` privacy is the capability. | Modify (1 new public function + 1 new private function + 1 runtime guard) |
| `foreman_server/aggregates/project.ex` | Extend `State` with `active_run_reservations: %{String.t() => reservation_metadata()}` (a map keyed by `run_id` storing canonical `command_id`, `sequence`, `run_start_payload`, and `project_id`); add `handle_command` for `project.reserve_run` (idempotent upsert into the map) and `project.release_run_reservation` (idempotent remove from the map); `project.archive` checks `map_size(state.active_run_reservations) == 0` before emitting `ProjectArchived`. `apply_event` for `ProjectRunReserved` folds the reservation metadata into the map; `apply_event` for `ProjectRunReservationReleased` removes the entry. The map is the projection of the event stream into state — fully derived from event log replay, no separate write. | Modify (State field + 2 new apply_events + 2 new handle_commands + 1 archive check) |
| `foreman_server/aggregates/run.ex` | Add `project_id` field to `Run.State` (between `task_id` and `status`); `initial_state` sets `project_id: nil`; `RunStarted` `apply_event` populates `state.project_id` from the payload; terminal-event handlers (`RunCompleted`, `RunFailed`, `RunCancelled`, `RunFlaggedStuck`, `RunBlocked`) emit `project_id: state.project_id` in the event payload so the reconciler can resolve the project from the event itself. The reconcile path uses `Run.load(run_id)` to rehydrate state. | Modify (1 State field + 1 apply_event + 5 handle_command event builders) |
| `foreman_server/run_admission.ex` | Thin delegate. `start/2` calls `CommandRouter.dispatch_run_start/2` (the protocol owner). No protocol logic in this module — calling `RunAdmission.start/2` is equivalent to calling `CommandRouter.dispatch_run_start/2`. The module exists to (a) give the public API a single documented name, (b) centralize the architecture test allowlist (only `RunAdmission` may call `dispatch_run_start/2`). The reconciler also calls `RunAdmission.start/2` to retry orphan reservations, using the idempotent reserve-and-run flow (the first step is idempotent when the run_id is already a key in the project's `active_run_reservations`). | New |
| `foreman_server/run_lifecycle_reconciler.ex` | Supervised GenServer. **Responsibility A (terminal-event subscription):** subscribes to `RunCompleted`, `RunFailed`, `RunCancelled`, `RunBlocked`, `RunFlaggedStuck`; reads `project_id` directly from the event payload (the typed event is the authoritative source); dispatches `project.release_run_reservation`. Sub-second happy-path release. **Responsibility B (scheduled crash-recovery pass, default 60s):** enumerates `(project_id, run_id)` pairs via `ProjectionStore.list_projects_with_active_runs/0` (projection used only for enumeration). For each pair, rehydrates `Run.load(run_id)` to read `Run.State.exists?` and `Run.State.terminal?` (event stream replay), and `Project.load(project_id)` to read `Project.State.active_run_reservations[run_id]` (event-stream-derived state). **Retry-not-release protocol:** if `Run.State.terminal? == true` → release. If `Run.State.exists? == false` → recover the reservation metadata from `active_run_reservations[run_id]` and call `RunAdmission.start(recovered_payload)` to retry the run.start (the reserve is idempotent; the run.start uses the deterministic command_id so concurrent appends are merged via actor-level event dedup). If `Run.State.exists? == true` and `Run.State.terminal? == false` → retain. The protocol never releases on absence alone (TOCTOU closed). | New |
| `foreman_server/events/project_run_reserved.ex` | `ProjectRunReserved{run_id, project_id, sequence, command_id, run_start_payload}` — append-only fact that a run was reserved; carries the canonical command ID and the full input needed to retry `run.start` (so the reconciler can recover the run.start payload from project state, not by re-scanning the event stream). `run_start_payload` is the verbatim input passed to `RunAdmission.start/2` (task_id, workflow_snapshot, etc.). | New |
| `foreman_server/events/project_run_reservation_released.ex` | `ProjectRunReservationReleased{run_id, project_id, sequence, reason}` — append-only fact that a run was released | New |
| `foreman_server/event_codec.ex` | Register `:project_run_reserved` and `:project_run_reservation_released` (typed modules + enforce_keys including `run_start_payload` for the reservation event). Extend `@enforce_keys_registry` for `RunCompleted` (`[:run_id, :project_id, :sequence]`), `RunFailed` (`[:run_id, :project_id, :sequence]`). Add `RunCancelled`, `RunFlaggedStuck`, and `RunBlocked` as typed events (currently untyped maps — AGENTS.md mandates typed events for every domain event): `RunCancelled => [:run_id, :project_id, :reason]`, `RunFlaggedStuck => [:run_id, :project_id, :flagged_at]`, `RunBlocked => [:run_id, :project_id, :phase_id, :reason]`. Both `@registry` and `@enforce_keys_registry` must be updated in lockstep (the comment at lines 80-83 of the existing codec explicitly requires this). | Modify (extend registry + 3 new event modules + 2 enforce_keys extensions) |
| `foreman_server/projection_store.ex` | Add `list_projects_with_active_runs/0` (returns `[{project_id, [run_id]}]` from `ProjectRunReserved`-derived projection). The reconciler is the ONLY caller; this function is used for enumeration only. **No `run_projection/1`** — the reconciliation path uses `Run.load(run_id)` and the typed event payload for safety decisions, never a projection. The previous design's `run_projection/1` was removed because it relied on projection reads for safety decisions, which races the event-commit boundary. | Modify (1 new query function) |
| `foreman_server/application.ex` | Add `RunLifecycleReconciler` to supervision tree under `ForemanServer.Supervisor`; configure `:run_reconciler_interval_ms` (default 60_000) | Modify (supervision tree) |
| `foreman_server/workflow/dispatcher.ex` | Replace direct `CommandGateway.dispatch_system(%{type: "run.start", ...})` call with `RunAdmission.start/2` (the ONLY legitimate caller of `run.start`) | Modify (1 call site) |
| `foreman_server/project_store.ex` | No change — `list/0` and `get/1` already exist | None |
| `foreman_server/telemetry.ex` (or equivalent) | Emit `[:foreman_server, :project, :register | :update | :archive | :read | :list | :run_reserved | :run_reservation_released]` and `[:foreman_server, :reconciler, :terminal_release | :orphan_retry]` with `duration_ms`, `outcome`, optional `code`/`retryable` (note: `:orphan_retry` replaces the v1.0.0 `:orphan_released` event — v1.0.1+ does not release on absence, it retries) | Modify (extend handlers) |
| `foreman_cli/cmd/foreman/project.go` (new) and `foreman_cli/cmd/foreman/main.go` (modify) | Five subcommands: `create`, `get`, `update`, `delete`, `list` | New + modify |
| `foreman_cli/internal/client/client.go` | Exit-code mapping for 6 documented codes (0,1,2,3,4,5) | Modify (extend error handling) |
| `docs/user-guide.md`, `docs/cli-reference.md` | Document the new `project` subcommand grouping, exit codes, and the `delete` ↔ `archive` mapping | Modify |
| `test/foreman_server_web/event_store_web_enforcement_test.exs` (new) | Mirror `event_store_enforcement_test.exs` for the web layer. Extend the allowlist to enforce the router-owned admission path: (a) every `CommandRouter.dispatch_run_start/2` call MUST be in `RunAdmission` (or `RunLifecycleReconciler` — the retry path); (b) every `CommandRouter.dispatch/2` call with `type: "run.start"` is rejected anywhere in production code (the runtime guard in `dispatch/2` rejects this; the test prevents regressions); (c) every `CommandGateway.dispatch_system/2` call with `type: "run.start"` is rejected anywhere in production code. Allowlist: `CommandRouter` (the `dispatch_run_start/2` function itself), `RunAdmission` (the protocol delegate), and `RunLifecycleReconciler` (the retry path). Excluded from the scan: `test/` and `run_test.exs` (aggregate unit tests call `Run.handle_command/2` directly and never dispatch through the router). | New |
| `test/foreman_server/event_codec_test.exs` (existing) | Add coverage for the two new event types (round-trip encode/decode) | Modify (extend) |

### 2d. Telemetry emission points (codified)
| Event | Emission point | Rationale |
|---|---|---|
| `[:foreman_server, :project, :read]` | `ProjectController.show/2` after read completes | Controller is the only ingress for reads; gateway is not on the path |
| `[:foreman_server, :project, :list]` | `ProjectController.index/2` after read completes | Same as `:read` |
| `[:foreman_server, :project, :register]` | `CommandGateway.dispatch_operator/2` after successful dispatch | Gateway is sole mutation ingress; emitting here covers both HTTP and direct-gateway callers |
| `[:foreman_server, :project, :update]` | `CommandGateway.dispatch_operator/2` after successful dispatch | Same as `:register` |
| `[:foreman_server, :project, :archive]` | `CommandGateway.dispatch_operator/2` after successful dispatch (success or `409 project_has_active_runs` — the aggregate rejected before append) | Same as `:register`; covers both the appended and the rejected cases |
| `[:foreman_server, :project, :run_reserved]` | `RunAdmission.start/2` after step 1 (`project.reserve_run`) appends successfully | Coordinator is the only caller; covers every reservation across the happy-path and the reservation-then-compensate path |
| `[:foreman_server, :project, :run_reservation_released]` | `RunAdmission.start/2` after **definitive-rejection compensation only** (`{:error, :phase_terminal}` / `{:error, :run_already_terminal}` — explicit allowlist), OR `RunLifecycleReconciler` after terminal-event release | The reservation is NEVER released on absence alone (TOCTOU); ambiguous failures retain the reservation and let the reconciler scheduled pass retry. Only two release sources in v1.0.1; emission is co-located with the dispatch that performed the release |
| `[:foreman_server, :reconciler, :terminal_release]` | `RunLifecycleReconciler.handle_info` for terminal event after `project.release_run_reservation` dispatch | Responsibility A (sub-second happy-path release); reason `:terminal_event` |
| `[:foreman_server, :reconciler, :orphan_retry]` | `RunLifecycleReconciler.handle_info` scheduled pass after re-dispatch of `RunAdmission.start(recovered_payload)` for an orphan (Run absent, reservation present) | Responsibility B (60s crash-recovery pass); reason `:orphan` — **replaces the v1.0.0 `:orphan_released` event**; v1.0.1 does not release on absence, it retries |
---

## 3. PRD Ambiguity Resolution

The four open ambiguities are resolved at the TRD stage as follows:

### AMB-001 — Numeric adoption target

**Resolution:** placeholder; no implementation change required. Set at TRD execution time after observing baseline adoption. PRD §5 row 1 (`% of new projects via API/CLI`) is the metric; the target value is the operational question, not a code question.

### AMB-003 — p99 latency for `GET /api/projects/:id`

**Resolution:** no SLO at v0.1; revisit after observing the first 1,000 requests. `[:foreman_server, :project, :read]` telemetry carries `duration_ms` to enable the post-hoc analysis. No code change beyond the telemetry handler.

### AMB-004 — Active-run definition (terminal states of the run aggregate)

**Resolution (binding for AC-004-4):** the active-run membership is event-sourced into `Project.State` as `active_run_reservations: %{String.t() => reservation_metadata()}`. The metadata is a struct/map containing the canonical `command_id` of the reserving command, the `run_id`, the `project_id`, the reservation `sequence`, and the `run_start_payload` (the full input needed to retry `run.start`). The predicate "does this project have active runs?" is a pure read of `Project.State` — `map_size(state.active_run_reservations) == 0` — no `RunStore` lookup, no race window, no read-model dependency from inside the aggregate. The retry payload is preserved as part of project state, so the reconciler can recover it from `Project.load(project_id)` (which returns the rehydrated `%Project.State{}`) without scanning the event stream or relying on projection reads.

The map is updated via two append-only events:

- `ProjectRunReserved{run_id, project_id, sequence, command_id, run_start_payload}` — appended by `Project.handle_command/2` for `project.reserve_run`. Stores the metadata under `run_id`. Idempotent: re-applying when `run_id` is already a key in the map returns `:ok` without emitting a new event. The `run_start_payload` is the same input that was passed to `RunAdmission.start/2` — the run aggregate's full envelope (task_id, workflow_snapshot, etc.) — and is preserved verbatim so the reconciler can replay the run.start deterministically.
- `ProjectRunReservationReleased{run_id, project_id, sequence, reason}` — appended by `Project.handle_command/2` for `project.release_run_reservation`. Removes the entry under `run_id`. Idempotent: re-applying when `run_id` is absent returns `:ok` without emitting an event.

**Run-start append path is restricted to the router-owned admission flow.** `CommandRouter` exposes two public dispatch functions and one private append primitive:

- `dispatch(command, timeout)` — public. Rejects any envelope with `type: "run.start"` (raises `ArgumentError` naming `ForemanServer.RunAdmission.start/2`). All single-command dispatch flows through this function.
- `dispatch_run_start(payload, timeout)` — public. The **only** legitimate path that can append `run.start`. The router owns the entire multi-step protocol internally:
  1. `do_dispatch(%{type: "project.reserve_run", payload: ..., command_id: ...})` (private primitive)
  2. On step 1 success: `do_dispatch(%{type: "run.start", payload: ..., command_id: ...})` (private primitive)
  3. On step 2 success: return `:ok`
  4. On step 2 **definitive** rejection (allowlist below): `do_dispatch(%{type: "project.release_run_reservation", payload: ..., command_id: ..., reason: :run_start_rejected})` (private primitive); return the error
  5. On step 2 **ambiguous** failure (timeout, retry exhaustion, connection loss): return the error with the reservation **retained**; the reconciler will resolve on its next scheduled pass
- `do_dispatch(command, timeout)` — `defp` private. The actual single-command append path. Not callable from outside the module. This is the only route by which any command reaches the event store.

`RunAdmission.start/2` is a thin delegate that calls `CommandRouter.dispatch_run_start/2`. It does not contain the protocol — calling `RunAdmission.start/2` is equivalent to calling `CommandRouter.dispatch_run_start/2`. The module exists to centralize the architecture test's allowlist (only `RunAdmission` may call `dispatch_run_start/2`) and to give the public API a single documented name.

**Compensation policy (binding for AC-004-4):** the `dispatch_run_start/2` path compensates (releases the reservation) **only** on a definitive non-append rejection of `run.start`. The allowlist is:

- `{:error, :project_archived}` — the run was rejected because the project was archived mid-flight
- `{:error, :run_already_terminal}` — the run aggregate was already in a terminal state
- `{:error, :invalid_envelope}` — the run.start envelope failed validation
- `{:error, :unknown}` — the run aggregate's `handle_command/2` returned an unexpected error

For ambiguous failures (timeout, retry exhaustion, connection loss), the reservation is **retained**. The `RunLifecycleReconciler` scheduled pass (default 60s) resolves the orphan reservation with a **retry-not-release** protocol. The protocol NEVER releases the reservation on absence alone — releasing on absence would recreate the archive race if a concurrent `RunAdmission` process successfully appends `run.start` between the reconciler's absence check and the release dispatch (TOCTOU race: check says absence, run.start appends concurrently, release deletes the reservation, archive succeeds while the run is active).

The protocol is:

1. **Enumerate candidates**: `ProjectionStore.list_projects_with_active_runs/0` returns the `(project_id, run_id)` pairs with non-empty `active_run_reservations`. Projection is used ONLY for enumeration; no safety decision is made from it.
2. **Rehydrate the run**: `Run.load(run_id)` (event stream replay) returns `Run.State`. If `Run.State.exists? == false`, the run was never started. If `Run.State.terminal? == true`, the run is in a terminal state. Otherwise the run is in flight.
3. **Rehydrate the project**: `Project.load(project_id)` returns `Project.State.active_run_reservations[run_id]` (event-stream-derived state) containing the recovery payload (`command_id`, `run_start_payload`, `sequence`). This is the authoritative source for the retry payload — the metadata is preserved as part of project state from the original `ProjectRunReserved` event (`apply_event` folds it into the map). The reconciler reads `Map.get(state.active_run_reservations, run_id)` to recover the canonical command ID and the full input needed to retry `run.start`.
4. **Decide**:
   - `Run.State.terminal? == true` → release the reservation via `dispatch(project.release_run_reservation)`. The run is in a terminal state; this covers the case where the terminal event was missed (e.g., subscription dropped).
   - `Run.State.exists? == false` (run never started) → RETRY the run.start. Call `RunAdmission.start(recovered_payload)` with the preserved `run_start_payload`. The first step (`project.reserve_run`) is idempotent (no new event appended when `run_id` is already a key in the map). The second step (`run.start`) uses the deterministic `command_id` from the original reservation, so concurrent `RunAdmission` processes are merged via actor-level event dedup. The reservation stays until the run is terminal.
   - `Run.State.exists? == true` and `Run.State.terminal? == false` (run is in flight) → retain the reservation. The terminal event will release it via the subscription path on sub-second latency.
5. **Recovery timeout**: if the retry's `run.start` returns a definitive rejection per the allowlist above (`:project_archived`, `:run_already_terminal`, `:invalid_envelope`, `:unknown`), release the reservation. If the retry fails ambiguously, retain for the next pass.

The reconciler ALSO subscribes to terminal events (Responsibility A) for the sub-second happy-path release. In that path, the terminal event carries `project_id` and `run_id` directly in its payload; the reconciler reads these and dispatches `project.release_run_reservation`. Both paths share the same authoritative state (event stream + project state), ensuring no behavioral drift between the scheduled pass and the subscription path.


**Run aggregate extension (binding for AC-004-4):** the terminal events used by the reconciler MUST carry `project_id`. Per `AGENTS.md`, every domain event is a typed struct; maps MUST NOT replace the event struct. The current state of the run event types (verified by direct file reads this session):

- `RunCompleted` — typed struct, codec registry entry `[:run_id, :sequence]` (line 95 of `event_codec.ex`) — must be extended to `[:run_id, :project_id, :sequence]`
- `RunFailed` — typed struct, codec registry entry `[:run_id, :sequence]` (line 96) — must be extended to `[:run_id, :project_id, :sequence]`
- `RunCancelled` — currently **untyped** (not in codec registry) — must be added as a typed struct with `project_id` in enforce_keys
- `RunFlaggedStuck` — currently **untyped** (not in codec registry) — must be added as a typed struct with `project_id` in enforce_keys
- `RunBlocked` — currently **untyped** (not in codec registry) — must be added as a typed struct with `project_id` in enforce_keys

Furthermore, `Run.State` (verified at `packages/foreman_server/lib/foreman_server/aggregates/run.ex:25-38`) does NOT currently store `project_id`. The terminal-event handlers at `run.ex:78-128` only project `run_id` and `sequence` from the payload; nothing reads `project_id` from the run's event stream. The TRD v1.0.1 requires:

1. Add `project_id` field to `Run.State` defstruct (between `task_id` and `status`)
2. `initial_state/0` sets `project_id: nil`
3. `Run.apply_event` for `RunStarted` (currently `run.ex:58-65`) populates `Run.State.project_id` from `Aggregate.get(payload, :project_id)`
4. `Run.handle_command` for terminal events (`RunCompleted`, `RunFailed`, `RunCancelled`, `RunFlaggedStuck`, `RunBlocked`) emits `project_id: state.project_id` in the event payload — the run aggregate holds `project_id` from `RunStarted` and never modifies it
5. Event codec registry updates: `RunCompleted => [:run_id, :project_id, :sequence]`, `RunFailed => [:run_id, :project_id, :sequence]`, `RunCancelled => [:run_id, :project_id, :reason]`, `RunFlaggedStuck => [:run_id, :project_id, :flagged_at]`, `RunBlocked => [:run_id, :project_id, :phase_id, :reason]`
6. Any existing tests that construct `RunCompleted`/`RunFailed` events must be updated to include `project_id` (the new `@enforce_keys` will fail tests that omit it; this is a deliberately breaking change to maintain replay integrity)
7. **Rehydration test (binding for AC-004-4):** given a run stream with only `RunStarted{run_id, project_id: "p1", task_id, workflow_snapshot}`, when `Run.load(run_id)` is called, then `Run.State.project_id == "p1"`. This proves the field is populated on replay, not merely on construction.

**Reservation metadata and project_id resolution (binding for the reconciler):** the reconciler reads reservation metadata (command_id, run_start_payload, project_id) from the project state, and run status from the run state. The two sources are derived independently from the event log.

- **Reservation metadata source (binding):** `Project.State.active_run_reservations[run_id]` (a map populated by `Project.apply_event(ProjectRunReserved)`) is the authoritative source for the reservation's `command_id`, `run_start_payload`, and `project_id`. The reconciler reads `Map.get(state.active_run_reservations, run_id)` to recover the canonical command ID and the full input needed to retry `run.start`. This is event-stream-derived state (the project aggregate folds every `ProjectRunReserved` event into the map during rehydration), NOT a projection lookup. The map IS the projection of the event stream, but the projection is computed deterministically from the event stream at every rehydration — there is no asynchronous lag.
- **Terminal-event subscription path (Responsibility A):** `project_id` is read directly from the terminal event payload (which is part of the event itself, the authoritative source). NO projection lookup. The reconciler passes the event's `project_id` and `run_id` to `dispatch(project.release_run_reservation)`.
- **Scheduled pass path (Responsibility B):** the safety decision is made from `Run.State.exists?` and `Run.State.terminal?` (from `Run.load(run_id)`). The retry payload is read from `Project.State.active_run_reservations[run_id]` (from `Project.load(project_id)`). Both sources are event-stream-derived. NO projection lookup.

**Projection store role (binding):** `ProjectionStore` is used ONLY for enumeration (`list_projects_with_active_runs/0` to enumerate candidates for the scheduled pass). The per-run safety decision is ALWAYS validated against the event stream (via aggregate rehydration). Projection reads are NOT suitable for any "is X the case?" decision because projections lag behind event commits.

**Architecture test enforcement (binding for AC-008-1):** `test/foreman_server_web/event_store_web_enforcement_test.exs` scans `lib/foreman_server/**/*.ex` and `lib/foreman_server_web/**/*.ex` and rejects any of: (a) `CommandRouter.dispatch_run_start/2` call outside `RunAdmission`; (b) `CommandRouter.dispatch/2` call with `type: "run.start"` anywhere in production code (the runtime guard in `dispatch/2` already rejects this; the test prevents regressions); (c) `CommandGateway.dispatch_system/2` call with `type: "run.start"` anywhere in production code. The test allowlist is `CommandRouter` (the `dispatch_run_start/2` function itself) and `RunAdmission` (the delegate). Excluded from the scan: `test/` and `run_test.exs` (aggregate unit tests call `Run.handle_command/2` directly and never dispatch through the router).
### AMB-005 — Hard cap value for `GET /api/projects`

**Resolution (binding for AC-016-7):** the cap is configurable at runtime via `Application.get_env(:foreman_server, :projects_list_max, 1000)`. Default 1000. The `X-Total-Count` response header **exposes the underlying full count of matching rows** (NOT the truncated body length) — clients can detect truncation by `X-Total-Count > len(body.projects)` OR `meta.truncated == true`. If the cap is hit, the response body is truncated and a `meta.truncated: true` field is added (the field is documented in the route's OpenAPI; the CLI's `--format=json` output surfaces it). Implementation: TRD-015 (list controller).

---

## 4. Master Task List

> **Format:** each task is a checkbox with `[satisfies REQ-NNN]`, hour estimate, dependency annotation, and a `Validates PRD ACs` field listing the AC IDs it implements. Tests are paired with `[verifies TRD-NNN] [satisfies REQ-NNN] [depends: TRD-NNN]`.
>
> **PR boundaries:** `### PR N:` sections are machine-parsed by `implement-trd-beads`. Each PR has a **Shippable State:** line describing the user-observable capability after the PR merges. A `## Sprint Planning` section (§5) groups PRs into calendar sprints for human readers only.

### PR 1: Active-Run Tracking Infrastructure

**Shippable State:** Project state carries an `active_run_reservations` map keyed by `run_id`; the run aggregate carries a `project_id` field populated on every `RunStarted` apply_event and rehydrated correctly on replay; `CommandRouter.dispatch_run_start/2` owns the multi-step admission protocol via a `defp do_dispatch/2` (unreachable from outside the module); `RunLifecycleReconciler` runs in two paths (terminal-event subscription + scheduled pass) using authoritative event-stream-derived state (event payload for subscription, `Project.load/2` + `Run.load/2` for the scheduled pass); the reconciler applies the **retry-not-release** protocol (NEVER releases on `Run.State.exists? == false` alone — retries `RunAdmission.start/2` with the preserved `run_start_payload` from `Project.State.active_run_reservations`); supervision tree includes `RunLifecycleReconciler`; `EventCodec` registry knows the two new reservation events plus `RunCompleted`/`RunFailed` extended with `project_id` and `run_id`; terminal-event subscription drives reservation release with sub-second happy-path latency; no projection read backs any safety decision (projection is enumeration only).

- [ ] **TRD-001** Add `active_run_reservations` map to `Project.State` with reservation metadata (4h) [satisfies REQ-004, AMB-004]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-004-4
  - Implementation ACs:
    - [ ] Given `Project.State`, when inspecting the struct, then the field is `active_run_reservations: %{String.t() => reservation_metadata()}` (NOT a `MapSet`).
    - [ ] Given `reservation_metadata()`, when typed, then it is `%{command_id: String.t(), project_id: String.t(), sequence: non_neg_integer(), run_start_payload: map()}`.
    - [ ] Given a `ProjectRunReserved{run_id, project_id, sequence, command_id, run_start_payload}` event, when `Project.apply_event/2` matches it, then `%State{state | active_run_reservations: Map.put(state.active_run_reservations, run_id, metadata)}`.
    - [ ] Given a `ProjectRunReservationReleased{run_id, project_id, sequence}` event, when `Project.apply_event/2` matches it, then `%State{state | active_run_reservations: Map.delete(state.active_run_reservations, run_id)}`.
    - [ ] Given `initial_state/0`, when invoked, then `active_run_reservations: %{}` (empty map, NOT empty MapSet).
    - [ ] Given the rehydrated state via `Project.load/2`, when a reconciler reads `Map.get(state.active_run_reservations, run_id)`, then it returns the full reservation metadata (preserving `run_start_payload` for retry).
  - Depends on: (none — first task in PR 1)

- [ ] **TRD-001-TEST** Active-run reservations map tests (2h) [verifies TRD-001] [satisfies REQ-004] [depends: TRD-001]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-004-4
  - Test cases:
    - [ ] Assert: empty initial state has `active_run_reservations == %{}`.
    - [ ] Assert: after `ProjectRunReserved` apply, the map has one entry keyed by `run_id`.
    - [ ] Assert: after `ProjectRunReservationReleased` apply, the map returns to empty.
    - [ ] Assert: rehydration via `Project.load/2` preserves the metadata (no event stream scan required).
    - [ ] Assert: re-applying `ProjectRunReserved` for an existing `run_id` is idempotent (does NOT create duplicate entries; map update is by key).
    - [ ] Assert: unknown atom keys are rejected by `%State{state | ...}` syntax (compile-time guard).

- [ ] **TRD-002** `ProjectRunReserved` and `ProjectRunReservationReleased` event structs + handle_command clauses (3h) [satisfies REQ-004, AMB-004]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3
  - Implementation ACs:
    - [ ] Given `ForemanServer.Events.ProjectRunReserved`, when defined, then `@enforce_keys [:run_id, :project_id, :sequence, :command_id, :run_start_payload]` and `@derive Jason.Encoder` precede `defstruct`.
    - [ ] Given `ForemanServer.Events.ProjectRunReservationReleased`, when defined, then `@enforce_keys [:run_id, :project_id, :sequence]` and `@derive Jason.Encoder` precede `defstruct`.
    - [ ] Given `Project.handle_command(:project.reserve_run, %{run_id: id, command_id: cid, run_start_payload: payload})`, when the run is already reserved, then it returns `:ok` without emitting a new event (idempotent upsert).
    - [ ] Given `Project.handle_command(:project.reserve_run, ...)`, when the run is new, then it emits `ProjectRunReserved` with the metadata.
    - [ ] Given `Project.handle_command(:project.release_run_reservation, %{run_id: id})`, when the run is reserved, then it emits `ProjectRunReservationReleased`.
    - [ ] Given `Project.handle_command(:project.release_run_reservation, ...)` for an unknown run, when invoked, then it returns `:ok` without emitting (idempotent release).
  - Depends on: TRD-001

- [ ] **TRD-002-TEST** Reservation event + handle_command tests (2h) [verifies TRD-002] [satisfies REQ-004] [depends: TRD-002]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3
  - Test cases:
    - [ ] Assert: `ProjectRunReserved` struct has the 5 `@enforce_keys`.
    - [ ] Assert: `ProjectRunReservationReleased` struct has the 3 `@enforce_keys`.
    - [ ] Assert: `:project.reserve_run` emits exactly one event for a new run.
    - [ ] Assert: `:project.reserve_run` on existing run is idempotent (no second event).
    - [ ] Assert: `:project.release_run_reservation` removes the entry from `active_run_reservations`.
    - [ ] Assert: `:project.release_run_reservation` on unknown run is idempotent.

- [ ] **TRD-003** Extend `Run.State` with `project_id` field; populate on `RunStarted` apply_event + replay correctness (2h) [satisfies REQ-004]
  - Validates PRD ACs: AC-004-2, AC-004-3
  - Implementation ACs:
    - [ ] Given `Run.State`, when inspecting the struct, then a new field `project_id: String.t() | nil` is declared.
    - [ ] Given `ForemanServer.Events.RunStarted{project_id: pid, run_id: rid, sequence: seq}`, when `Run.apply_event/2` matches, then `%State{state | project_id: pid, run_id: rid, last_sequence: seq}` (project_id is set on the same apply as run_id).
    - [ ] Given `Run.load/2`, when called with a stream that contains a `RunStarted` event, then the rehydrated state has `project_id` populated (NOT nil).
    - [ ] Given the terminal-event structs (`RunCompleted`, `RunFailed`, `RunCancelled`, `RunFlaggedStuck`, `RunBlocked`), when re-inspected, then each carries `@enforce_keys` that include `project_id` and `run_id`.
  - Depends on: (none)

- [ ] **TRD-003-TEST** Run.State.project_id rehydration + terminal-event codec tests (1h) [verifies TRD-003] [satisfies REQ-004] [depends: TRD-003]
  - Validates PRD ACs: AC-004-2, AC-004-3
  - Test cases:
    - [ ] Assert: `RunStarted` apply_event populates `project_id`.
    - [ ] Assert: `Run.load(run_id)` returns a state with `project_id` populated from the event stream.
    - [ ] Assert: terminal events reject construction without `project_id` (KeyError on `defstruct`).
    - [ ] Assert: `EventCodec.decode!` reconstructs the typed terminal event with `project_id` accessible via struct field access.

- [ ] **TRD-004** `RunAdmission.start/2` public facade → `CommandRouter.dispatch_run_start/2` internal entry → `defp do_dispatch/2` private protocol (4h) [satisfies REQ-004, AMB-004]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-004-4
  - Implementation ACs:
    - [ ] Given the call graph, when documented in module headers, then it is **one-way and acyclic**: `Dispatcher / Reconciler → RunAdmission.start/2 → CommandRouter.dispatch_run_start/2 → defp do_dispatch/2`. No caller skips the facade.
    - [ ] Given `ForemanServer.RunAdmission.start(project_id, run_start_payload)`, when invoked, then it is a `def` public function that emits the `:run_admission, :start` telemetry event and forwards to `CommandRouter.dispatch_run_start/2`.
    - [ ] Given `ForemanServer.CommandRouter.dispatch_run_start/2`, when invoked, then it is `def` but module-documented as **internal** (callers MUST use `RunAdmission.start/2`). It computes a deterministic `command_id = sha256("run.start." <> project_id <> "." <> run_id <> "." <> workflow_snapshot_hash)` and forwards to `defp do_dispatch/2`.
    - [ ] Given `defp do_dispatch(command_id, payload)`, when invoked, then it executes the two-step protocol: step 1 = `project.reserve_run` (idempotent — `run_id` already-keyed reservation re-applies as `:ok`); step 2 = `:run.start` with the same `command_id` so actor-level event dedup merges concurrent appends.
    - [ ] Given step 2 returns a definitive-rejection error from the allowlist (`:phase_terminal`, `:project_archived`, `:unknown_project`, `:unknown_workflow`), when observed, then `do_dispatch/2` invokes the compensation path (`project.release_run_reservation`). Compensation is restricted to definitive rejections — ambiguous failures (timeout, transport) RETAIN the reservation for the reconciler's scheduled pass.
    - [ ] Given `defp do_dispatch/2`, when a test attempts to call it from outside the module, then it fails with `UndefinedFunctionError` (compile-time guard against future bypass).
  - Depends on: TRD-001, TRD-002, TRD-003

- [ ] **TRD-004-TEST** RunAdmission facade + router-owned admission path tests (2h) [verifies TRD-004] [satisfies REQ-004] [depends: TRD-004]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-004-4
  - Test cases:
    - [ ] Assert: `RunAdmission.start/2` is `def` and public.
    - [ ] Assert: `RunAdmission.start/2` emits `:run_admission, :start` telemetry.
    - [ ] Assert: `RunAdmission.start/2` is the only call site of `CommandRouter.dispatch_run_start/2` (architecture scan verifies no other module calls it).
    - [ ] Assert: `CommandRouter.dispatch_run_start/2` succeeds with deterministic `command_id`.
    - [ ] Assert: `defp do_dispatch/2` is NOT callable from outside the module (compile-time guard test).
    - [ ] Assert: idempotent reserve — calling `RunAdmission.start/2` twice with the same `run_id` appends only one `ProjectRunReserved` event.
    - [ ] Assert: actor-level dedup — concurrent run.start with the same `command_id` merges (single `RunStarted` event).
    - [ ] Assert: definitive rejection (`:phase_terminal`) triggers compensation release.
    - [ ] Assert: ambiguous failure (timeout mock) RETAINS the reservation for the reconciler.


- [ ] **TRD-005** `RunLifecycleReconciler` with subscribed + scheduled paths (retry-not-release protocol) (4h) [satisfies REQ-004, AMB-004]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-004-4
  - Test cases for the 5-step protocol:
    - [ ] Assert: terminal event (`RunCompleted`/`RunFailed`) subscription triggers release within 1s happy-path latency.
    - [ ] Assert: subscription path reads `project_id` and `run_id` from the event payload (NOT from a projection lookup).
    - [ ] Assert: scheduled pass enumerates via `ProjectionStore.list_projects_with_active_runs/0` (enumeration only).
    - [ ] Assert: scheduled pass rehydrates `Project.load/2` and `Run.load/2` for the safety decision.
    - [ ] Assert: `Run.State.terminal? == true` → release reservation.
    - [ ] Assert: `Run.State.exists? == false` (run never started) → RETRY: call `RunAdmission.start(recovered_payload)` with `run_start_payload` from `Project.State.active_run_reservations[run_id]` — NEVER release on absence alone (TOCTOU race closed).
    - [ ] Assert: `Run.State.exists? == true && Run.State.terminal? == false` → retain for next pass.
    - [ ] Assert: retry's `run.start` returns definitive rejection → release; ambiguous failure → retain.
  - Implementation ACs:
    - [ ] Given `ForemanServer.RunLifecycleReconciler`, when defined, then it is a GenServer with two paths: `:subscribed` (terminal event handler) and `:scheduled` (periodic poll, default 30s).
    - [ ] Given a terminal event arrives via the event store subscription, when the handler matches `RunCompleted` or `RunFailed`, then it dispatches `project.release_run_reservation` with `project_id` and `run_id` from the event payload.
    - [ ] Given the scheduled pass fires, when it iterates over `(project_id, run_id)` pairs from the projection, then for each pair it loads `Run.State` and `Project.State`.
    - [ ] Given the per-pair decision logic, when it executes, then it implements the 4-branch table from the test cases (terminal/release, absent/retry, exists-not-terminal/retain, definitive-rejection-during-retry/release).
  - Depends on: TRD-001, TRD-002, TRD-003, TRD-004

- [ ] **TRD-005-TEST** Reconciler retry-not-release protocol tests (3h) [verifies TRD-005] [satisfies REQ-004] [depends: TRD-005]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-004-4
  - Test cases:
    - [ ] Assert: terminal event subscription releases within 1s of the terminal event being committed.
    - [ ] Assert: subscription uses event payload `project_id`/`run_id` directly (no projection lookup).
    - [ ] Assert: scheduled pass enumerates via projection but does NOT use projection for safety decisions.
    - [ ] Assert: `Run.State.exists? == false` triggers RETRY (NOT release).
    - [ ] Assert: retry uses `run_start_payload` from `Project.State.active_run_reservations[run_id]`.
    - [ ] Assert: retry's `run.start` with deterministic `command_id` dedupes via the Run aggregate.
    - [ ] Assert: retry definitive-rejection → release; retry ambiguous-failure → retain for next pass.
    - [ ] Assert: idempotent reserve on retry path — `project.reserve_run` does NOT emit a second `ProjectRunReserved`.
    - [ ] Assert: end-to-end TOCTOU test — concurrent run.start between scheduled pass's load and reconcile path is correctly handled (no archive race).

- [ ] **TRD-006** Supervision tree wiring + `EventCodec` registry updates + admission-facade-bypass architecture test (2h) [satisfies REQ-004, AMB-004]
  - Validates PRD ACs: AC-004-1, AC-004-4
  - Implementation ACs:
    - [ ] Given `application.ex`, when the supervision tree is updated, then `RunLifecycleReconciler` is added as a child under the existing supervisor with `restart: :permanent`.
    - [ ] Given `EventCodec`, when the registry is updated, then `ProjectRunReserved`, `ProjectRunReservationReleased`, `RunCancelled`, `RunFlaggedStuck`, and `RunBlocked` are registered with their `@enforce_keys` and `Jason.Encoder` derives.
    - [ ] Given `RunCompleted` and `RunFailed`, when the codec's `enforce_keys` is updated, then both require `project_id` and `run_id` (in addition to existing fields) — UNCONDITIONAL codec decode rejects events lacking these.
    - [ ] Given the admission-facade-bypass architecture test (`event_store_web_enforcement_test.exs` or a sibling `admission_facade_enforcement_test.exs`), when it scans `lib/foreman_server/aggregates/`, `lib/foreman_server/workflow/`, `lib/foreman_server_web/`, and any other caller modules, then a direct call to `CommandRouter.dispatch_run_start/2` (other than from `ForemanServer.RunAdmission`) fails the test. The allowlist contains only `run_admission.ex`.
    - [ ] Given the bypass test, when it scans the same set, then a direct call to `RunAdmission.start/2` from `lib/foreman_server_web/` also fails (the facade is server-internal; web must use `CommandGateway.dispatch_operator/2`).
  - Depends on: TRD-002, TRD-003, TRD-004

- [ ] **TRD-006-TEST** Codec registry + supervision + facade-bypass tests (2h) [verifies TRD-006] [satisfies REQ-004] [depends: TRD-006]
  - Validates PRD ACs: AC-004-1, AC-004-4
  - Test cases:
    - [ ] Assert: `EventCodec.decode!` reconstructs `ProjectRunReserved` from a JSON map (round-trip).
    - [ ] Assert: `EventCodec.decode!` rejects `RunCompleted` lacking `project_id` (raise on missing enforce_key).
    - [ ] Assert: `RunLifecycleReconciler` is in the supervision tree (start_link assertion in application test).
    - [ ] Assert: bypass test fails when a stub module calls `CommandRouter.dispatch_run_start/2` directly.
    - [ ] Assert: bypass test fails when a stub web module calls `RunAdmission.start/2` directly.
    - [ ] Assert: bypass test passes when `RunAdmission.start/2` calls `CommandRouter.dispatch_run_start/2` (the allowlisted single seam).

### PR 2: Mutations, Telemetry, Admission Boundary

**Shippable State:** `POST /api/commands` with `type: "project.update"` or `type: "project.archive"` flows end-to-end against a running server; `project.archive` returns `409 project_has_active_runs` with the active run ids list when `Project.State.active_run_reservations` is non-empty (the active-run check uses the in-state map, NOT a fresh query); identity-binding mismatch returns `400` with `reason: ":aggregate_id_mismatch"`; the web layer cannot bypass the gateway (architecture test fails on any direct `EventStore.append_to_stream`, `CommandRouter.append_*`, `CommandRouter.dispatch_run_start/2`, `RunAdmission.start/2`, or `RunLifecycleReconciler.retry_run_start/2` call in `lib/foreman_server_web/`); the workflow dispatcher's run-start path routes through `RunAdmission.start/2` (the public facade — no parallel saga path, no bypass of the facade); the call graph `Dispatcher/Reconciler → RunAdmission.start/2 → CommandRouter.dispatch_run_start/2 → defp do_dispatch/2` is acyclic (architecture bypass test scans for any caller other than the allowlisted seam); telemetry handlers emit the 6 documented project lifecycle events; `ProjectionStore` exposes `list_projects_with_active_runs/0` for reconciler enumeration (no `run_projection/1`).

- [ ] **TRD-007** Update `command_controller.ex` allowlist tables + 409 version-conflict mapping for `project.update` and `project.archive` (3h) [satisfies REQ-002, REQ-003]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3, AC-002-4, AC-002-5, AC-002-6, AC-003-2, AC-003-3, AC-003-4
  - Implementation ACs:
    - [ ] Given `@allowed_types` is updated, when `project.update` envelope is POSTed to `/api/commands`, then the controller accepts the type (not rejected at the type-validation gate).
    - [ ] Given `@allowed_types` is updated, when `project.archive` envelope is POSTed, then the controller accepts the type.
    - [ ] Given `aggregate_prefix/1` returns `"project"` for both types, when the controller builds the envelope, then `aggregate_id` is `"project:<project_id>"`.
    - [ ] Given `id_field_for/1` returns `:project_id` for both types, when the controller reads the payload, then `project_id` is extracted correctly.
    - [ ] Given an unknown type is POSTed, when the controller validates, then the existing `{:error, :invalid_envelope}` path returns `400` with `reason: ":invalid_envelope"` (regression-safe).
    - [ ] Given `project.register` is POSTed, when the controller validates, then behavior is unchanged from v0.1.4.
    - [ ] Given `project.update` or `project.archive` is dispatched, when the controller responds, then the body matches `{status: "accepted", result: {project_id: ...}}` (AC-003-2 / AC-003-3; locks the existing 201 envelope shape against accidental change for the new mutation types).
    - [ ] Given the actor's bounded retry path exhausts on `wrong_expected_version`, when the controller renders the response, then it returns `409 Conflict` with `code: "version_conflict"` and `current_version` in the body (AC-003-4 — field name `code` per PRD AC-003-4; not `error`). The `current_version` is the **authoritative stream version** from the actor's propagated tuple `{:error, {:wrong_expected_version, current_version}}` — NOT a projection lookup (§3/§7 A8 forbids projection reads for safety decisions). The actor's retry-exhaustion return is extended from `{:error, :wrong_expected_version}` to `{:error, {:wrong_expected_version, current_version}}` where `current_version` is the **stream version already held by the actor** (per AGENTS.md: the actor owns a separate `stream version` and rehydrates via `Aggregate.load/2` on each conflict-recovery reload). The change is propagating the version the actor already has in scope from the last reload — no fresh branch over aggregate types, no `state.last_sequence` lookup (not every `%State{}` field is named that way), no projection read. The gateway passes the tuple through unchanged; the controller renders it as `409` + `code: "version_conflict"` + `current_version`.
  - Depends on: (none — first task in PR 2)

- [ ] **TRD-007-TEST** Controller allowlist + HTTP mutation envelope + 409 mapping tests (2h) [verifies TRD-007] [satisfies REQ-002, REQ-003] [depends: TRD-007, TRD-008]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3, AC-002-4, AC-002-5, AC-002-6, AC-003-2, AC-003-3, AC-003-4
  - Test cases:
    - [ ] Assert: `project.update` envelope is accepted (no reject).
    - [ ] Assert: `project.archive` envelope is accepted.
    - [ ] Assert: `aggregate_id` is `"project:<id>"` for both types.
    - [ ] Assert: unknown type returns `400` with `reason: ":invalid_envelope"`.
    - [ ] Assert: `project.register` regression-safe.
    - [ ] Assert: HTTP 201 envelope for `project.update` — body matches `{status: "accepted", result: {project_id: ...}}` (AC-003-2; end-to-end through the controller).
    - [ ] Assert: HTTP 201 envelope for `project.archive` — body matches `{status: "accepted", result: {project_id: ...}}` (AC-003-3; end-to-end through the controller).
    - [ ] Assert: HTTP 409 `version_conflict` mapping when the actor's bounded retry path exhausts on `wrong_expected_version` (AC-003-4; controller-rendering only — the actor contract is verified by TRD-024-TEST). The controller rendering test stubs the gateway to return `{:error, {:wrong_expected_version, current_version}}` (matching the actor contract from TRD-024) and asserts the controller renders `409 Conflict` with body containing `code: "version_conflict"` and `current_version: <propagated>` (per PRD AC-003-4 — field name `code`, not `error`) — explicitly NOT a projection lookup (the test does not call `ProjectionStore.get_project/1` and the controller does not take a projection read for the version).

- [ ] **TRD-008** Update `command_gateway.ex` allowlist + `validate_aggregate_id/1` clauses for `project.update` and `project.archive` (3h) [satisfies REQ-002, REQ-015]
  - Validates PRD ACs: AC-002-7, AC-002-8, AC-015-1, AC-015-2, AC-015-3, AC-015-4, AC-015-5
  - Implementation ACs:
    - [ ] Given `@allowed_operator_types` is updated, when an envelope with `type: "project.update"` reaches the gateway, then the allowlist gate does not reject.
    - [ ] Given `@allowed_operator_types` is updated, when `project.archive` reaches the gateway, then the allowlist gate does not reject.
    - [ ] Given the type is in the allowlist, when `validate_aggregate_id/1` runs for `project.update`, then the identity-binding clause executes (not the fallback `:ok` clause).
    - [ ] Given `project.update` envelope with `aggregate_id: "project:victim"` and `payload.project_id: "other"`, when the gateway runs `validate_aggregate_id/1`, then it returns `{:error, {:invalid_envelope, :aggregate_id_mismatch}}` and no event is appended.
    - [ ] Given `project.archive` envelope with mismatched ids, same expected outcome.
    - [ ] Given `project.update` envelope with matching ids, then `validate_aggregate_id/1` returns `:ok` and the command proceeds to the actor.
    - [ ] Given the gateway allowlist gate admits the type, when `validate_aggregate_id/1` runs, then it executes before any call to the actor (no event is appended on mismatch).
  - Depends on: TRD-007

- [ ] **TRD-008-TEST** Gateway allowlist + identity-binding validator tests (2h) [verifies TRD-008] [satisfies REQ-002, REQ-015] [depends: TRD-008]
  - Validates PRD ACs: AC-002-7, AC-002-8, AC-015-1, AC-015-2, AC-015-3, AC-015-4, AC-015-5
  - Test cases:
    - [ ] Assert: `project.update` and `project.archive` are in `@allowed_operator_types` (regression guard).
    - [ ] Assert: a non-allowed type (e.g. `task.delete`) is still rejected at the allowlist gate.
    - [ ] Assert: positive case — matching ids pass through to actor.
    - [ ] Assert: negative case — mismatched ids return `{:error, {:invalid_envelope, :aggregate_id_mismatch}}`.
    - [ ] Assert: HTTP path — controller returns `400` with `reason: ":aggregate_id_mismatch"` (current controller behavior; regression-safe).
    - [ ] Assert: actor is NOT called on mismatch (event log is unchanged).

- [ ] **TRD-009** Web-layer CQRS enforcement test (extended allowlist for reconciler) (2h) [satisfies REQ-008]
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-008-3
  - Implementation ACs:
    - [ ] Given a controller file under `lib/foreman_server_web/`, when the architecture test scans it, then any call to `EventStore.append_to_stream`, `CommandRouter.append_*`, `RunLifecycleReconciler.retry_run_start/2`, or `EventStore.Adapter` dispatch fails the test.
    - [ ] Given a controller file, when the test scans it, then calls to `CommandGateway.dispatch_operator/2` are allowed (sole permitted write path).
    - [ ] Given `ProjectController` is added, when the test runs, then the new controller is included in the scan set (no false negatives).
    - [ ] Given a controller file with `RunLifecycleReconciler` direct import, when the test runs, then it fails (reconciler is server-internal; web must not import).
  - Depends on: (none)

- [ ] **TRD-009-TEST** Self-verifying scan (1h) [verifies TRD-009] [satisfies REQ-008] [depends: TRD-009]
  - Validates PRD ACs: AC-008-1, AC-008-2, AC-008-3
  - Test cases:
    - [ ] Assert: a controller file with a direct `EventStore.append_to_stream` call fails the test.
    - [ ] Assert: a controller file with `RunLifecycleReconciler.retry_run_start/2` call fails the test.
    - [ ] Assert: a controller file with a `CommandGateway.dispatch_operator/2` call passes.
    - [ ] Assert: `ProjectController` is in the scan set.

- [ ] **TRD-010** Telemetry handlers for project lifecycle events (2h) [satisfies REQ-012]
  - Validates PRD ACs: AC-012-1, AC-012-2, AC-012-3, AC-012-4, AC-012-5, AC-012-6
  - Implementation ACs:
    - [ ] Given `GET /api/projects/:id` completes (success or error), then `[:foreman_server, :project, :read]` is emitted with `duration_ms` and `outcome`.
    - [ ] Given `project.register` is dispatched, then `[:foreman_server, :project, :register]` is emitted.
    - [ ] Given `project.update` is dispatched, then `[:foreman_server, :project, :update]` is emitted.
    - [ ] Given `project.archive` is dispatched (success or `409`), then `[:foreman_server, :project, :archive]` is emitted.
    - [ ] Given `outcome: :error`, then the event includes `code` and `retryable` from the response envelope.
    - [ ] Given `GET /api/projects` (list) completes, then `[:foreman_server, :project, :list]` is emitted with `duration_ms`, `count: <n>`, and `outcome`.
  - Depends on: TRD-007 (so mutation telemetry is co-located with the gateway allowlist work)

- [ ] **TRD-010-TEST** Telemetry handler tests (1h) [verifies TRD-010] [satisfies REQ-012] [depends: TRD-010]
  - Validates PRD ACs: AC-012-1, AC-012-2, AC-012-3, AC-012-4, AC-012-5, AC-012-6
  - Test cases:
    - [ ] Assert: each of the 6 events is emitted with the documented fields.
    - [ ] Assert: `:error` events include `code` and `retryable`.
    - [ ] Assert: list event includes `count`.

- [ ] **TRD-011** `Project.handle_command :project.archive` active-run check using `active_run_reservations` map (2h) [satisfies REQ-004, AMB-004]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-004-4
  - Implementation ACs:
    - [ ] Given `Project.handle_command(:project.archive, payload)`, when `map_size(state.active_run_reservations) == 0`, then it emits `ProjectArchived` (no rejection).
    - [ ] Given `Project.handle_command(:project.archive, payload)`, when the map has one or more entries, then it returns `{:error, :project_has_active_runs, Map.keys(state.active_run_reservations)}` (no event appended).
    - [ ] Given the test contract enumerates the run aggregate's terminal states (from `run.ex`), when the test runs, then for every non-terminal state the archive is rejected (the active-run check is "are there reservations?", not "are runs running?" — reservations are released by the reconciler when runs terminate).
    - [ ] Given a previous dispatch returned `{:error, :project_has_active_runs}` and the reconciler has since released all reservations, when `project.archive` is retried, then the command succeeds.
  - Depends on: TRD-001, TRD-002

- [ ] **TRD-011-TEST** Project.archive active-run check tests (2h) [verifies TRD-011] [satisfies REQ-004] [depends: TRD-011]
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3, AC-004-4
  - Test cases:
    - [ ] Assert: project with empty `active_run_reservations` accepts `project.archive`.
    - [ ] Assert: project with one reservation rejects with `:project_has_active_runs` and the run id list.
    - [ ] Assert: project with multiple reservations rejects with the full run id list.
    - [ ] Assert: previous reject + reservations released → retry succeeds.
    - [ ] Assert: terminal-state enumeration in `run.ex` matches the test contract (parametrized test against documented non-terminal states).
    - [ ] Assert: reconciler-released reservation (via `ProjectRunReservationReleased` apply) unblocks archive.

- [ ] **TRD-012** Workflow dispatcher migration to `RunAdmission.start/2` (public facade) (2h) [satisfies REQ-004]
  - Validates PRD ACs: AC-004-1, AC-004-4
  - Implementation ACs:
    - [ ] Given `ForemanServer.Workflow.Dispatcher`, when the run-start path is invoked, then it calls `RunAdmission.start(project_id, run_start_payload)` (the public facade). It MUST NOT call `CommandRouter.dispatch_run_start/2` or `defp do_dispatch/2` directly — the architecture bypass test fails any other call site.
    - [ ] Given the call graph `Dispatcher → RunAdmission.start/2 → CommandRouter.dispatch_run_start/2 → defp do_dispatch/2`, when grepped, then it is **one-way and acyclic**: the only call to `CommandRouter.dispatch_run_start/2` is from `RunAdmission`, and the only call to `defp do_dispatch/2` is from `CommandRouter`.
    - [ ] Given the workflow dispatcher integration tests, when run, then they pass against the facade path.
  - Depends on: TRD-004

- [ ] **TRD-012-TEST** Workflow dispatcher migration tests (1h) [verifies TRD-012] [satisfies REQ-004] [depends: TRD-012]
  - Validates PRD ACs: AC-004-1, AC-004-4
  - Test cases:
    - [ ] Assert: dispatcher calls `RunAdmission.start/2` (mock verifies the facade is the call site).
    - [ ] Assert: dispatcher does NOT call `CommandRouter.dispatch_run_start/2` or `defp do_dispatch/2` directly (architecture bypass regression guard).
    - [ ] Assert: end-to-end integration test — workflow triggers run start, reservation is created, run.start succeeds.

- [ ] **TRD-013** `ProjectionStore.list_projects_with_active_runs/0` enumeration-only API (1h) [satisfies REQ-004]
  - Validates PRD ACs: AC-004-1, AC-004-4
  - Implementation ACs:
    - [ ] Given `ProjectionStore.list_projects_with_active_runs/0`, when invoked, then it returns `[{project_id, run_id}, ...]` tuples from the projection.
    - [ ] Given `ProjectionStore.run_projection/1`, when invoked (legacy), then it raises `UndefinedFunctionError` (REMOVED — projection is NOT used for safety decisions).
    - [ ] Given the reconciler scheduled pass, when it enumerates, then it calls `list_projects_with_active_runs/0` (NOT a projection read for a single run).
  - Depends on: TRD-005 (PR 1), TRD-006 (PR 1)

- [ ] **TRD-013-TEST** Projection enumeration tests (1h) [verifies TRD-013] [satisfies REQ-004] [depends: TRD-013]
  - Validates PRD ACs: AC-004-1, AC-004-4
  - Test cases:
    - [ ] Assert: `list_projects_with_active_runs/0` returns tuples in `(project_id, run_id)` format.
    - [ ] Assert: empty store returns `[]`.
    - [ ] Assert: legacy `run_projection/1` raises `UndefinedFunctionError`.
    - [ ] Assert: reconciler scheduled pass test asserts that the projection is read ONLY via `list_projects_with_active_runs/0`.
- [ ] **TRD-024** Actor retry-exhaustion contract extension (carries authoritative stream version) (1h) [satisfies REQ-003]
  - Validates PRD ACs: AC-003-4
  - Implementation ACs:
    - [ ] Given `ForemanServer.Aggregate.Actor` (or the equivalent aggregate actor module) handles the bounded retry path, when retry exhaustion occurs on `wrong_expected_version`, then the actor returns `{:error, {:wrong_expected_version, current_version}}` where `current_version` is the **stream version already held by the actor** (per AGENTS.md: the actor owns a separate `stream version` and rehydrates via `Aggregate.load/2` on each conflict-recovery reload). The change is propagating the version the actor already has in scope from the last reload — no fresh branch over aggregate types, no `state.last_sequence` lookup (not every `%State{}` field is named that way), no projection read. The tuple is the new contract; downstream callers (gateway, controller) advertise the same shape.
  - Depends on: TRD-001 (PR 1)

- [ ] **TRD-024-TEST** Actor retry-exhaustion contract test (real Aggregate.Actor, no mocks) (1h) [verifies TRD-024] [satisfies REQ-003] [depends: TRD-024]
  - Validates PRD ACs: AC-003-4
  - Test cases:
    - [ ] Assert: real `Aggregate.Actor` — start the actor with a deterministic `command_id` stream version, then append a successful event (advance stream version to N+1), then inject a sustained `wrong_expected_version` failure (e.g., disable the event store append or attach a stub that always returns `{:error, :wrong_expected_version}` to the append path), then dispatch a command that triggers the bounded retry path. After `@max_conflict_retries` (default 3) the actor returns `{:error, {:wrong_expected_version, current_version}}` where `current_version` matches the actor's stream version AT THE POINT OF RETRY EXHAUSTION (the value the actor already has in scope from its last `Aggregate.load/2` reload — verified by inspecting the actor's state via `:sys.get_state/1`).
    - [ ] Assert: the actor's stream version does NOT change after retry exhaustion (no partial event application).

### PR 3: HTTP Read Routes

**Shippable State:** `GET /api/projects/:id` returns the projection behind Bearer auth with `200 OK` or `404 not_found` / `401 unauthorized`; `GET /api/projects?include_archived=<bool>` returns the list with default hard cap 1000 and `X-Total-Count` header; empty list is `200 OK + {projects: []}` (NOT an error); `meta.truncated: true` is set when the cap is hit; all four list responses (`GET /:id`, `GET /`, the bearer-auth plug, and the existing `POST /api/commands`) are exercised end-to-end against a running server with both happy-path and failure cases.

- [ ] **TRD-014** `ProjectController.show/2` for `GET /api/projects/:id` (2h) [satisfies REQ-001, REQ-007, REQ-011]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3, AC-007-1, AC-007-2, AC-011-1
  - Implementation ACs:
    - [ ] Given `GET /api/projects/:id` is requested, when the controller matches, then it calls `ProjectionStore.get_project/1` (read-only) and returns `200 OK` with `{project: <projection>}` envelope.
    - [ ] Given the projection store returns `:not_found`, when the controller responds, then it returns `404` with `{error: "not_found", reason: ":project_not_found"}` envelope.
    - [ ] Given the Bearer auth plug is engaged, when no token is supplied, then the request short-circuits to `401` before the controller runs.
    - [ ] Given a malformed `:id` (non-UUID, contains `/`), when Phoenix routes it, then it returns `404` (no route match) without invoking the controller.
    - [ ] Given `X-Request-Id` is supplied, when the controller responds, then it echoes the value in the response header.
  - Depends on: (none — first task in PR 3)

- [ ] **TRD-014-TEST** `ProjectController.show/2` tests (2h) [verifies TRD-014] [satisfies REQ-001, REQ-007, REQ-011] [depends: TRD-014]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3, AC-007-1, AC-007-2, AC-011-1
  - Test cases:
    - [ ] Assert: `GET /api/projects/<existing>` returns 200 with `{project: <projection>}`.
    - [ ] Assert: `GET /api/projects/<missing>` returns 404 with structured envelope.
    - [ ] Assert: missing Bearer token returns 401 (plug short-circuits).
    - [ ] Assert: malformed `:id` returns 404 (no controller invocation).
    - [ ] Assert: `X-Request-Id` is echoed.
    - [ ] Assert: archived project is still readable by id (no auto-filter).

- [ ] **TRD-015** `ProjectController.index/2` for `GET /api/projects` with hard cap + `meta.truncated` (3h) [satisfies REQ-007, REQ-016]
  - Validates PRD ACs: AC-007-3, AC-007-4, AC-016-1, AC-016-2, AC-016-3, AC-016-4, AC-016-5
  - Implementation ACs:
    - [ ] Given `GET /api/projects` is requested with no `include_archived`, when the controller runs, then it returns `200 OK + {projects: [...non-archived...]}` (archived excluded by default).
    - [ ] Given `?include_archived=true`, when the controller runs, then archived projects ARE in the response list.
    - [ ] Given the projection store returns more than `1000` projects, when the controller truncates, then the response body contains exactly 1000 projects AND `meta.truncated: true`.
    - [ ] Given truncation occurs, when the controller responds, then the `X-Total-Count` header equals the underlying full count (NOT the truncated length).
    - [ ] Given the projection store returns 0 projects, when the controller runs, then it returns `200 OK + {projects: []}` (NOT an error).
    - [ ] Given `?limit=N` is supplied, when the controller runs, then the response is capped at `min(N, hard_cap)`.
    - [ ] Given a malformed query string (e.g., `?include_archived=notabool`), when the controller parses, then it returns `400` with `reason: ":invalid_query"` envelope.
  - Depends on: TRD-014 (read infrastructure exists)

- [ ] **TRD-015-TEST** `ProjectController.index/2` tests (2h) [verifies TRD-015] [satisfies REQ-007, REQ-016] [depends: TRD-015]
  - Validates PRD ACs: AC-007-3, AC-007-4, AC-016-1, AC-016-2, AC-016-3, AC-016-4, AC-016-5
  - Test cases:
    - [ ] Assert: default response excludes archived projects.
    - [ ] Assert: `?include_archived=true` includes archived.
    - [ ] Assert: >1000 projects truncates to 1000 with `meta.truncated: true`.
    - [ ] Assert: `X-Total-Count` equals the underlying full count, NOT the truncated length.
    - [ ] Assert: empty projection returns `{projects: []}`.
    - [ ] Assert: `?limit=N` respects the cap.
    - [ ] Assert: malformed query string returns 400.

- [ ] **TRD-016** Router wiring + auth pipeline + read-route smoke test (1h) [satisfies REQ-001, REQ-011, REQ-016]
  - Validates PRD ACs: AC-001-1, AC-011-1, AC-016-1
  - Implementation ACs:
    - [ ] Given `foreman_server_web/router.ex`, when the routes are updated, then `GET /api/projects` and `GET /api/projects/:id` are mounted under the existing `BearerAuth` pipeline.
    - [ ] Given the auth pipeline, when applied, then unauthenticated requests to BOTH routes return `401` before the controller runs.
    - [ ] Given a smoke test script (`mix test test/integration/project_read_routes_test.exs`), when run against a live server, then both routes succeed end-to-end and verify the four documented response shapes (`200`, `200-empty`, `404`, `401`).
    - [ ] Given the existing `POST /api/commands` route, when the smoke test runs, then `project.register` succeeds with HTTP `201 Created` and response body `{status: "accepted", result: {project_id: ...}}` (regression guard for REQ-003 201 envelope shape; locks the gateway success response against accidental changes).
  - Depends on: TRD-014, TRD-015

- [ ] **TRD-016-TEST** Router + auth + read-route smoke tests (1h) [verifies TRD-016] [satisfies REQ-001, REQ-003, REQ-011, REQ-016] [depends: TRD-016]
  - Validates PRD ACs: AC-001-1, AC-011-1, AC-016-1
  - Test cases:
    - [ ] Assert: router test verifies both routes mount under the `BearerAuth` pipeline.
    - [ ] Assert: integration smoke test verifies 200, 200-empty, 404, 401 in sequence.
    - [ ] Assert: regression — `POST /api/commands` with `project.register` returns HTTP 201 and body matches `{status: "accepted", result: {project_id: ...}}` (REQ-003 envelope shape).

### PR 4: Go CLI, Exit Codes, Docs

**Shippable State:** `foreman project {create,get,update,delete,list}` all run end-to-end against a running server; exit codes 0/1/2/3/4/5 are documented and exercised; `foreman project list` defaults to a table with columns `ID, PATH, ARCHIVED, REGISTERED, VERSION`, accepts `--include-archived` and `--format=json|ndjson`; user guide and CLI reference reflect the new surface.

- [ ] **TRD-017** `foreman project create` Go subcommand (2h) [satisfies REQ-009, REQ-010]
  - Validates PRD ACs: AC-009-1, AC-010-1, AC-010-2, AC-010-3
  - Implementation ACs:
    - [ ] Given `--id`, `--path`, `--task-provider` are supplied, when the CLI runs, then it POSTs `/api/commands` with `type: "project.register"` and the required payload.
    - [ ] Given `FOREMAN_API_URL` and `FOREMAN_API_TOKEN` are set, then the existing `internal/client` is used (no new client code path).
    - [ ] Given `--format=json` is passed, then the response envelope is printed to stdout as JSON.
    - [ ] Given no `--format`, then human-readable output (id and short summary).
    - [ ] Given `--idempotency-key=<key>`, then `command_id = sha256("project.create.<key>")`.
    - [ ] Given no `--idempotency-key`, then `command_id = sha256("project.create." + path + "." + task_provider)`.
  - Depends on: PR 1 (mutation gate open — TRD-007/TRD-008)

- [ ] **TRD-017-TEST** `project create` CLI tests (1h) [verifies TRD-017] [satisfies REQ-009, REQ-010] [depends: TRD-017]
  - Validates PRD ACs: AC-009-1, AC-010-1, AC-010-2, AC-010-3
  - Test cases:
    - [ ] Assert: successful create POSTs the right envelope.
    - [ ] Assert: idempotency-key derivation matches the contract.
    - [ ] Assert: env vars drive auth.
    - [ ] Assert: `--format=json` outputs JSON.

- [ ] **TRD-018** `foreman project get` Go subcommand (1h) [satisfies REQ-009, REQ-010]
  - Validates PRD ACs: AC-009-2, AC-010-1, AC-010-2, AC-010-3
  - Implementation ACs:
    - [ ] Given `<id>` is supplied, when the CLI runs, then it calls `GET /api/projects/<id>` and prints the projection.
    - [ ] Given `--format=json`, then JSON output.
    - [ ] Given no `--format`, then human-readable.
  - Depends on: TRD-014 (read route exists)

- [ ] **TRD-018-TEST** `project get` CLI tests (1h) [verifies TRD-018] [satisfies REQ-009, REQ-010] [depends: TRD-018]
  - Validates PRD ACs: AC-009-2, AC-010-1, AC-010-2, AC-010-3
  - Test cases:
    - [ ] Assert: GET path is `/api/projects/<id>`.
    - [ ] Assert: 404 → exit 2 (per TRD-022).
    - [ ] Assert: `--format=json` output.

- [ ] **TRD-019** `foreman project update` Go subcommand (2h) [satisfies REQ-009, REQ-010]
  - Validates PRD ACs: AC-009-3, AC-010-1, AC-010-2, AC-010-3
  - Implementation ACs:
    - [ ] Given `<id>` and `--task-provider` are supplied, when the CLI runs, then it POSTs `/api/commands` with `type: "project.update"`.
    - [ ] Given `--idempotency-key`, then `command_id = sha256("project.update.<key>")`.
    - [ ] Given no `--idempotency-key`, then `command_id = sha256("project.update." + id + "." + task_provider)`.
  - Depends on: PR 1 (mutation gate open — TRD-007/TRD-008)

- [ ] **TRD-019-TEST** `project update` CLI tests (1h) [verifies TRD-019] [satisfies REQ-009, REQ-010] [depends: TRD-019]
  - Validates PRD ACs: AC-009-3, AC-010-1, AC-010-2, AC-010-3
  - Test cases:
    - [ ] Assert: update POSTs the right envelope.
    - [ ] Assert: idempotency-key derivation.

- [ ] **TRD-020** `foreman project delete` Go subcommand (2h) [satisfies REQ-009, REQ-010, REQ-013]
  - Validates PRD ACs: AC-009-4, AC-010-1, AC-010-2, AC-010-3
  - Implementation ACs:
    - [ ] Given `<id>` is supplied, when the CLI runs, then it POSTs `/api/commands` with `type: "project.archive"` (the soft-delete).
    - [ ] Given `--idempotency-key`, then `command_id = sha256("project.delete.<key>")`.
    - [ ] Given the server returns 409, then the CLI exits with code 3 (active-runs block).
    - [ ] Given the server returns 404, then the CLI exits with code 2.
    - [ ] Given `--force` is supplied AND the server returns 409, then the CLI prints the active run ids list to stderr and exits 3 (FORCE does NOT bypass — by design).
  - Depends on: PR 1 (TRD-007/TRD-008) + TRD-011 (active-run check)

- [ ] **TRD-020-TEST** `project delete` CLI tests (1h) [verifies TRD-020] [satisfies REQ-009, REQ-010, REQ-013] [depends: TRD-020]
  - Validates PRD ACs: AC-009-4, AC-010-1, AC-010-2, AC-010-3
  - Test cases:
    - [ ] Assert: delete POSTs `project.archive`.
    - [ ] Assert: 409 → exit 3.
    - [ ] Assert: 404 → exit 2.
    - [ ] Assert: idempotency-key derivation.
    - [ ] Assert: `--force` does NOT bypass 409.

- [ ] **TRD-021** `foreman project list` Go subcommand (3h) [satisfies REQ-017, REQ-013]
  - Validates PRD ACs: AC-017-1, AC-017-2, AC-017-3, AC-017-4, AC-017-5, AC-017-6, AC-017-7
  - Implementation ACs:
    - [ ] Given `foreman project list` is invoked, then it calls `GET /api/projects?include_archived=false` and prints the default table with columns `ID, PATH, ARCHIVED, REGISTERED, VERSION`.
    - [ ] Given `--include-archived`, then `?include_archived=true` and archived projects are in the table.
    - [ ] Given `--format=json`, then a single JSON array to stdout.
    - [ ] Given `--format=ndjson`, then each project on its own line as a JSON object.
    - [ ] Given the server returns 200 + empty list, then exit 0.
    - [ ] Given 401, then exit 4.
    - [ ] Given 5xx, then exit 5.
    - [ ] Given `meta.truncated: true` in the body, then print a warning to stderr (per §2c / TRD Self-Critique #4).
  - Depends on: TRD-015 (list route exists), TRD-022 (exit-code mapping)

- [ ] **TRD-021-TEST** `project list` CLI tests (2h) [verifies TRD-021] [satisfies REQ-017, REQ-013] [depends: TRD-021]
  - Validates PRD ACs: AC-017-1, AC-017-2, AC-017-3, AC-017-4, AC-017-5, AC-017-6, AC-017-7
  - Test cases:
    - [ ] Assert: default table columns.
    - [ ] Assert: `--include-archived` flag passed through.
    - [ ] Assert: `--format=json` outputs a single JSON array.
    - [ ] Assert: `--format=ndjson` outputs one JSON object per line.
    - [ ] Assert: empty list → exit 0.
    - [ ] Assert: 401 → exit 4.
    - [ ] Assert: 5xx → exit 5.
    - [ ] Assert: truncation warning to stderr.

- [ ] **TRD-022** Exit-code mapping in `internal/client` (1h) [satisfies REQ-013]
  - Validates PRD ACs: AC-013-1, AC-013-2, AC-013-3, AC-013-4, AC-013-5, AC-013-6
  - Implementation ACs:
    - [ ] Given a successful run, exit 0.
    - [ ] Given a usage error (missing required flag), exit 1 and a usage message to stderr.
    - [ ] Given the server returns 404 (`not_found` or `project_archived`), exit 2.
    - [ ] Given the server returns 409 (`version_conflict` or `project_has_active_runs`), exit 3.
    - [ ] Given the server returns 401, exit 4.
    - [ ] Given the server returns any 5xx, exit 5.
  - Depends on: (none — pure CLI logic)

- [ ] **TRD-022-TEST** Exit-code mapping tests (1h) [verifies TRD-022] [satisfies REQ-013] [depends: TRD-022]
  - Validates PRD ACs: AC-013-1..AC-013-6
  - Test cases:
    - [ ] Assert: each documented exit code is emitted in its documented scenario.
    - [ ] Assert: usage error path emits a usage message to stderr and exits 1.

- [ ] **TRD-023** User guide + CLI reference docs (2h) [satisfies REQ-014]
  - Validates PRD ACs: AC-014-1, AC-014-2
  - Implementation ACs:
    - [ ] Given `docs/user-guide.md` is updated, then the `project` section documents all five subcommands (`create`, `get`, `update`, `delete`, `list`) with examples and a note that `delete` is a soft-delete (archive).
    - [ ] Given `docs/cli-reference.md` is updated, then `foreman project delete --help` text states the operation is a soft-delete and that an active run blocks it.
    - [ ] Given `docs/cli-reference.md` is updated, then `foreman project list --help` documents the default table columns, `--include-archived`, and `--format` flags.
    - [ ] Given `docs/user-guide.md` is updated, then a "performance / scaling" note explains the list endpoint's hard cap (default 1000) and `X-Total-Count` behavior.
  - Depends on: TRD-017, TRD-018, TRD-019, TRD-020, TRD-021, TRD-022 (subcommands + exit codes are stable)

- [ ] **TRD-023-TEST** Docs example verification (0.5h) [verifies TRD-023] [satisfies REQ-014] [depends: TRD-023]
  - Validates PRD ACs: AC-014-1, AC-014-2
  - Test cases:
    - [ ] Assert: every command example in the user guide runs without error against a live server (manual or scripted smoke).
    - [ ] Assert: `foreman project delete --help` text contains the soft-delete and active-run note.
    - [ ] Assert: `foreman project list --help` text documents the documented flags.

### Cross-PR dependencies (graph)

```
PR 1 (Active-Run Tracking Infrastructure):
  TRD-001 (no deps — first task in PR 1)
  TRD-001 -> TRD-002 (events require map field)
  TRD-003 (no deps — parallel to TRD-001)
  TRD-001, TRD-002, TRD-003 -> TRD-004 (facade needs map + events + Run field)
  TRD-001, TRD-002, TRD-003, TRD-004 -> TRD-005 (reconciler needs map for retry payload + facade for retry entrypoint)
  TRD-002, TRD-003, TRD-004 -> TRD-006 (supervision + codec + bypass test)

PR 2 (Mutations, Telemetry, Admission Boundary):
  TRD-007 (no deps — first task in PR 2)
  TRD-007 -> TRD-008 (gateway allowlist + identity-binding)
  TRD-009 (no deps — web-layer CQRS test allowlist; parallel to TRD-007)
  TRD-007 -> TRD-010 (telemetry)
  TRD-001, TRD-002 -> TRD-011 (active-run check using active_run_reservations map)
  TRD-004 -> TRD-012 (dispatcher routes through facade)
  TRD-005, TRD-006 -> TRD-013 (projection enumeration API)
  TRD-001 -> TRD-024 (actor retry-exhaustion contract extension); TRD-024 -> TRD-024-TEST (real Aggregate.Actor contract verification, no mocks — does NOT extend the main critical path; runs in parallel after TRD-024 completes)

PR 3 (HTTP Read Routes):
  TRD-014 (no deps — first task in PR 3)
  TRD-014 -> TRD-015
  TRD-014, TRD-015 -> TRD-016

PR 4 (Go CLI, Exit Codes, Docs):
  TRD-007, TRD-008 -> TRD-017 (mutations reachable)
  TRD-014 -> TRD-018 (GET /api/projects/:id)
  TRD-007, TRD-008 -> TRD-019 (mutations reachable)
  TRD-007, TRD-008, TRD-011 -> TRD-020 (delete with 409 handling)
  TRD-015, TRD-022 -> TRD-021 (list)
  TRD-022 (no deps — pure CLI logic)
  TRD-017, TRD-018, TRD-019, TRD-020, TRD-021, TRD-022 -> TRD-023
```

Critical path (longest chain of `Depends on:` edges through implementation tasks, computed strictly from task-level annotations): **three chains tie at 5 implementation tasks** — `(a) TRD-001 → TRD-002 → TRD-004 → TRD-005 → TRD-013` (PR 1 only), `(b) TRD-001 → TRD-002 → TRD-004 → TRD-006 → TRD-013` (PR 1 only), `(c) TRD-001 → TRD-002 → TRD-011 → TRD-020 → TRD-023` (PR 1 ↔ PR 2 ↔ PR 4). The cross-PR-critical-path chain is `(c)` because it spans PR boundaries. **Parallel branches that do NOT extend the main critical path:** `TRD-007 → TRD-008 → TRD-020` (PR 2, feeds `TRD-020` but `TRD-011` is the bottleneck through the chain); `TRD-001 → TRD-024 → TRD-024-TEST` (3-node parallel branch off `TRD-001` for actor retry-exhaustion contract); `TRD-014 → TRD-015 → TRD-016` (PR 3) and `TRD-014 → TRD-018 → TRD-023` / `TRD-014 → TRD-015 → TRD-021 → TRD-023` (PR 3 ↔ PR 4) — bounded at 4 tasks; `TRD-003 → TRD-004` (TRD-003 has no deps, so `TRD-002 → TRD-003` is NOT an edge); `TRD-022 → TRD-023` (TRD-022 has no deps). **Length:** 5 implementation tasks on the main critical path (matches the §11 Dependency clarity scorecard claim). Test tasks run in parallel with their paired impl (each test depends only on its own impl, except `TRD-007-TEST` which depends on both `TRD-007` and `TRD-008` — a cross-impl test dep that does not extend the impl critical path; `TRD-008` is already needed by `TRD-020`).

### Task estimate summary

| Bucket | Count | Hours |
|---|---|---|
| Implementation tasks | 24 | 54 |
| Test tasks | 24 | 35.5 |
| **Total** | **48** | **89.5** |
| PR 1 (impl + test) | 12 | 31 |
| PR 2 (impl + test) | 16 | 27 |
| PR 3 (impl + test) | 6 | 11 |
| PR 4 (impl + test) | 14 | 20.5 |

No task exceeds 4h; TRD-001 (4h) is the longest; no task requires breakdown.

---

## 5. Sprint Planning

This section is human-readable only. `implement-trd-beads` does not parse it. PRs map to time-boxed sprints as follows.

### Sprint 1: Active-Run Tracking Infrastructure (PR 1, ~31h)

- `Project.State.active_run_reservations` map keyed by `run_id` with `{command_id, project_id, sequence, run_start_payload}`
- `ProjectRunReserved` / `ProjectRunReservationReleased` events with `run_start_payload` for retry
- `Run.State.project_id` populated on `RunStarted` apply_event; rehydration test
- `RunAdmission.start/2` public facade → `CommandRouter.dispatch_run_start/2` internal entry → `defp do_dispatch/2` private protocol
- `RunLifecycleReconciler` with subscribed + scheduled paths (retry-not-release protocol)
- Supervision tree wires reconciler; EventCodec registry updated
- Admission-facade-bypass architecture test ensures no caller bypasses the facade

### Sprint 2: Mutations, Telemetry, Admission Boundary (PR 2, ~27h)

- Controller + gateway allowlists admit `project.update` and `project.archive`
- Identity-binding validator rejects cross-project `aggregate_id` mismatches with `400 aggregate_id_mismatch`
- Web-layer CQRS architecture test allowlists reconciler retry
- Telemetry handlers emit the 6 documented project lifecycle events
- `project.archive` active-run check uses `map_size(state.active_run_reservations) == 0` (race-safe — NOT a fresh query)
- Workflow dispatcher migrates to `RunAdmission.start/2` facade (no direct router/reconciler call)
- `ProjectionStore.list_projects_with_active_runs/0` enumeration-only API; legacy `run_projection/1` REMOVED
- Controller maps actor retry-exhaustion tuple `{:error, {:wrong_expected_version, current_version}}` to 409 `version_conflict` with `current_version` (no projection lookup per A8); actor contract extended via `Aggregate.Actor.handle_call(:command, _, _)` retry path

### Sprint 3: HTTP Read Routes (PR 3, ~11h)

- `GET /api/projects/:id` returns the projection behind Bearer auth with `200` / `404` / `401`
- `GET /api/projects?include_archived=<bool>` returns the list with hard cap 1000
- Empty list is `200 OK + {projects: []}` (not an error)
- `meta.truncated: true` is set when the cap is hit; `X-Total-Count` exposes underlying full count
- Router + BearerAuth pipeline integration smoke test

### Sprint 4: Go CLI, Exit Codes, Docs (PR 4, ~20.5h)

- `foreman project {create,get,update,delete,list}` all run end-to-end
- Exit codes 0/1/2/3/4/5 mapped (0=success, 1=usage, 2=not_found, 3=conflict/active-runs, 4=auth, 5=server error)
- `foreman project list` defaults to table with `ID, PATH, ARCHIVED, REGISTERED, VERSION`; `--include-archived` and `--format=json|ndjson` work
- User guide and CLI reference reflect the new surface; `--force` documented as NOT bypassing 409

---

## 6. Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 (Must) | `GET /api/projects/:id` returns the projection | TRD-014 (show), TRD-016 (router pipeline) | TRD-014-TEST, TRD-016-TEST |
| REQ-002 (Must) | Both allowlist layers admit `project.update` and `project.archive` | TRD-007 (controller), TRD-008 (gateway) | TRD-007-TEST, TRD-008-TEST |
| REQ-003 (Must) | `POST /api/commands` returns 201 envelope; mutating dispatch propagates a 409 `version_conflict` with `current_version` on retry exhaustion | TRD-007 (controller 201 envelope + 409 mapping), TRD-024 (actor retry-exhaustion contract extension), TRD-016 (router pipeline regression) | TRD-007-TEST (AC-003-2 201 update, AC-003-3 201 archive, AC-003-4 409 mapping), TRD-024-TEST (AC-003-4 actor contract — real Aggregate.Actor), TRD-016-TEST (AC-003-1 201 register regression case) |
| REQ-004 (Must) | `project.archive` rejects with active runs | TRD-011 | TRD-011-TEST |
| REQ-005 (Must) | Failed dispatch leaves no record to dedup | (existing actor behavior) | (covered by REQ-006 idempotency test) |
| REQ-006 (Must) | CLI `command_id` is deterministic | TRD-017, TRD-019, TRD-020 | TRD-017-TEST, TRD-019-TEST, TRD-020-TEST |
| REQ-007 (Must) | Structured error envelope on new GET routes | TRD-014, TRD-015 | TRD-014-TEST, TRD-015-TEST |
| REQ-008 (Must) | Web-layer CQRS enforcement test | TRD-009 | TRD-009-TEST |
| REQ-009 (Must) | `foreman project` subcommand grouping | TRD-017, TRD-018, TRD-019, TRD-020, TRD-021 | TRD-017-TEST, TRD-018-TEST, TRD-019-TEST, TRD-020-TEST, TRD-021-TEST |
| REQ-010 (Must) | CLI conventions (env, long flags, JSON) | TRD-017..TRD-022 | TRD-017-TEST..TRD-022-TEST |
| REQ-011 (Must) | Bearer auth on `GET /api/projects/:id` | TRD-016 (regression — BearerAuth pipeline covers routes) | TRD-016-TEST |
| REQ-012 (Should) | Telemetry for project lifecycle | TRD-010 | TRD-010-TEST |
| REQ-013 (Should) | Documented exit-code map | TRD-022 | TRD-022-TEST |
| REQ-014 (Could) | User guide + CLI reference | TRD-023 | TRD-023-TEST |
| REQ-015 (Must) | Identity-binding validator | TRD-008 (gateway identity-binding clause) | TRD-008-TEST |
| REQ-016 (Should) | `GET /api/projects` list | TRD-015 (list controller), TRD-016 (router pipeline) | TRD-015-TEST, TRD-016-TEST |
| REQ-017 (Should) | `foreman project list` subcommand | TRD-021 | TRD-021-TEST |

**Traceability check:** 17 requirements covered, 0 uncovered, 0 orphaned annotations. The PRD defines 78 unique AC IDs (across AC-001-1 through AC-017-x); the TRD explicitly cites 66 of them in `Validates PRD ACs:` annotations across tasks (some ACs are cited in multiple tasks — e.g. AC-003-4 is cited in both TRD-007-TEST and TRD-024-TEST — for layered coverage). The remaining 12 are satisfied implicitly through REQ coverage — when a TRD task satisfies a REQ, it satisfies every AC under that REQ per the PRD's REQ→AC mapping, even if not all AC IDs are listed verbatim. No AC is unsatisfied; the gap is annotation density, not coverage.

---

## 7. Architecture Self-Critique (≥2 issues)

| # | Issue | Resolution |
|---|---|---|
| A1 | REQ-002 (allowlist) and REQ-015 (identity validator) both modify `command_gateway.ex` as separate concerns. A future developer adding a new operator type may update `@allowed_operator_types` but forget the matching `validate_aggregate_id/1` clause, opening cross-project command injection. | TRD-008 adds a doc comment to `@allowed_operator_types` listing the relationship, AND a development-only assertion (`mix test --only dev_guard`) that every entry in `@allowed_operator_types` (other than the three pre-existing ones) has a matching `validate_aggregate_id/1` clause. Co-located in TRD-008 because both touch the same module. |
| A2 | REQ-012 telemetry emission point is ambiguous in the PRD (mixes "when the gateway completes" and "when the response is generated"). Different events have different natural emission points. | §2d codifies: read events emit from the controller (gateway is not on the path); mutation events emit from `CommandGateway.dispatch_operator/2` (the sole mutation ingress, covers both HTTP and direct-gateway callers). |
| A3 | The list endpoint's hard cap (AMB-005) is hardcoded to 1000 in the AC but not configurable at runtime. | §3 (AMB-005) and TRD-015 (list controller) make the cap configurable via `Application.get_env(:foreman_server, :projects_list_max, 1000)`. AC-016-7 is satisfied by the union of "at most the configured cap" and "`X-Total-Count` reflects the **underlying full count** of matching rows" (clients detect truncation via `X-Total-Count > len(body.projects)` or `meta.truncated == true`). |
| A4 | The CLI `list` subcommand has no paging support; with more than 1000 projects the response is silently truncated. | TRD-015 emits `meta.truncated: true` when truncated; TRD-021 (CLI list) prints a warning to stderr when this flag is present; TRD-023 (docs) adds a "performance / scaling" note explaining the cap and `X-Total-Count` semantics. |
| A5 | **Sentinel-as-capability flaw (v1.0.1, BLOCKER).** The original design used a sentinel `:reserved` value returned from the gateway as a capability flag, with all callers pattern-matching `{:ok, :reserved}` to mean "you may proceed". This conflated a return-code idiom with an authorization capability, opening the door to a future caller forgetting the sentinel check and bypassing `project.archive` reservation enforcement. | The router-owned admission path replaces this with `RunAdmission.start/2` (public facade) → `CommandRouter.dispatch_run_start/2` (internal-but-public, allowlist = `run_admission.ex` only) → `defp do_dispatch/2` (private protocol). No sentinel: admission is a function call, not a return value. Architecture bypass test (TRD-006) scans `lib/foreman_server/` for direct callers outside the allowlist and fails the build on a violation. |
| A6 | **Compensable-error allowlist (v1.0.1, BLOCKER).** If `RunAdmission` releases `ProjectRunReservationReleased` on every failed append, ambiguous failures (network blip, transient lock timeout) would lose the reservation even though the underlying run state is unknown — making `project.archive` succeed while the run might still become active. | Compensation is restricted to a definitive-rejection allowlist (e.g. `:phase_terminal`, aggregate-state-validator rejections). Ambiguous failures retain the reservation; reconciler scheduled pass is the only path that may retry or release based on authoritative state. |
| A7 | **Terminal event `project_id` resolution (v1.0.1, BLOCKER).** The original design had the reconciler look up `project_id` via `Run.State.project_id` on terminal event receipt, but `Run.State.project_id` is only populated AFTER `RunStarted` is applied — if the terminal event arrives before the corresponding `RunStarted` apply completes (out-of-order in the subscription path), the lookup returns `nil` and the reconciler drops the release. | Terminal events (`RunCompleted`, `RunFailed`) are extended with `project_id` and `run_id` in their payload. The reconciler subscription path uses the event payload directly (`event.project_id`, `event.run_id`) — no re-query of `Run.State`. The scheduled path uses `Run.load(run_id).project_id` from authoritative event-stream-rehydrated state. Both paths converge. |
| A8 | **Reconciler authoritative source (v1.0.1, BLOCKER).** The reconciler originally read project/run status from the projection store, which is derived data and may lag the event log. A safety decision (release reservation, archive project) made against stale projection data can race with in-flight event application. | Both reconciler paths derive decisions from authoritative event-stream-rehydrated state, but via different access patterns reflecting what data they have at the point of decision. **Subscription path**: the terminal event payload is itself the authoritative signal — the run just became terminal — so no fresh `Run.load/1` is needed (per A7); the path reads `event.project_id`, `event.run_id`, and emits `project.release_run_reservation`. **Scheduled path**: no event is in flight, so the path MUST re-load authoritative state — it enumerates via `ProjectionStore.list_projects_with_active_runs/0` (a SCAN, not a safety query), then for each `(project_id, run_id)` re-loads `Project.load/1` (for `active_run_reservations` map) and `Run.load/1` (for current status) to decide retry vs. release. The projection store is enumeration-only — it never answers a safety question. |
| A9 | **MapSet discards retry metadata (v1.0.1, BLOCKER).** The original design stored `active_run_ids :: MapSet.t(String.t())` on `Project.State`. `Project.load/1` returns the rehydrated MapSet, but a MapSet only stores the `run_id` strings — the original `run_start_payload`, `command_id`, and `sequence` required for retry are lost. | `active_run_reservations` is a `Map.t(String.t(), {command_id, project_id, sequence, run_start_payload})` keyed by `run_id`. `ProjectRunReserved` event carries `run_start_payload` and folds it into the map; `Project.load/1` rehydrates the map from the event stream; the reconciler reads the full metadata without re-querying. |
| A10 | **Retry-not-release closes TOCTOU race (v1.0.1, BLOCKER).** The original release-on-absence protocol released the reservation when `Run.State.exists? == false`, allowing a window: between the absence check and the release dispatch, a concurrent `RunAdmission` could successfully append `run.start`, and the subsequent release would then delete the reservation — letting `project.archive` proceed while the run is still active. | Reconciler NEVER releases on absence alone. If `Run.State.exists? == false`, RETRY `RunAdmission.start(recovered_payload)` using the deterministic `command_id` from the reservation. Step 1 (`project.reserve_run`) is idempotent (existing map key) and step 2 (`run.start`) uses the deterministic `command_id`, so actor-level event dedup at the Run aggregate merges concurrent appends. Reservation is only released on authoritative terminal event or aggregate-state rejection. |

## 8. Task Coverage Analysis (≥2 issues)

| # | Issue | Resolution |
|---|---|---|
| C1 | REQ-007 (structured error envelope) has no dedicated TRD task; the envelope applies to the new GET routes (REQ-001, REQ-016). | TRD-014 and TRD-015 (the `show/2` and `index/2` controllers) each include the envelope in their implementation ACs (the "Given an error, when the response is generated, then the body conforms to REQ-007" case). The PRD's REQ-007 is satisfied by the union of TRD-014 and TRD-015. |
| C2 | REQ-011 (bearer auth) is satisfied by the existing plug; no new code is added. The PRD requires the new routes to be subject to the plug. | TRD-016 (router wiring test) includes a bearer-auth check for both new routes: 401 on missing token, 401 on invalid token. The existing plug's coverage is regression-safe by test, not by code. |
| C3 | REQ-003 (201 envelope + 409 version-conflict mapping) is partially regression-safe (AC-003-1) but AC-003-2/3/4 introduce new contract surface that requires both actor-level and controller-level test coverage. | **Split across three tasks.** AC-003-1 (project.register 201) is regression-tested in TRD-016-TEST (the router + read-route smoke test): asserts `POST /api/commands` with `project.register` returns HTTP 201 with body `{status: "accepted", result: {project_id: ...}}`. AC-003-2 (project.update 201) and AC-003-3 (project.archive 201) are tested in TRD-007-TEST (controller HTTP integration): asserts the 201 envelope shape for the new mutation types. AC-003-4 (409 `version_conflict` with `current_version`) is layered across: TRD-007-TEST (controller rendering — stubs the gateway to return `{:error, {:wrong_expected_version, current_version}}` and asserts the 409 response body contains `code: "version_conflict"` + `current_version`, NOT a projection lookup) AND TRD-024-TEST (real Aggregate.Actor contract — forces sustained `wrong_expected_version` failures on the actor's bounded retry path, asserts the actor returns `{:error, {:wrong_expected_version, current_version}}` with `current_version` matching the actor's stream version at the point of exhaustion). TRD-024 (actor retry-exhaustion contract extension) carries the actor contract change; TRD-001-TEST is left untouched. |

## 9. Dependency and Estimate Review (≥1 issue)

| # | Issue | Resolution |
|---|---|---|
| D1 | TRD-011 (active-run check via `map_size(state.active_run_reservations) == 0`) is implementation-light by v1.0.1: the predicate is a single map-size check on event-stream-rehydrated state, with no fresh query into `Run.State` or `RunStore`. The remaining research risk is verifying that the `run_start_payload` schema (carried in `ProjectRunReserved` and folded into `active_run_reservations`) is byte-compatible with the workflow dispatcher's payload format. The 2h estimate covers the predicate + `run_start_payload` schema check + 4 test cases (happy path, terminal-rejection, missing-payload edge, race-recovery retry). Re-estimate if the workflow dispatcher schema diverges. |
| D2 | TRD-010 (telemetry handlers for the 6 project lifecycle events: `[:foreman_server, :project, :created]`, `:updated`, `:archived`, `:read`, `:list`, `:active_run_reservation_changed]`) assumes the existing telemetry handler pattern is reusable. The 2h estimate covers attaching handlers in `telemetry.ex` (or equivalent) and wiring the 6 emit points codified in §2d. Re-estimate if the telemetry taxonomy needs extension. |

## 10. Testability Review

| # | Issue | Resolution |
|---|---|---|
| T1 | AC-016-7 references a fixed cap value (1000). If the cap is later changed, the AC is still satisfied. | TRD-015 (list controller) makes the cap configurable (§3 AMB-005 resolution; config-driven default 1000). The TRD rewrites the AC intent as "at most the configured cap entries" so the test is bound to the config, not the literal 1000. |
| T2 | AC-015-3 references specific line numbers in the controller (`command_controller.ex:101`, `:49-52`). Line numbers are fragile. | TRD-008-TEST tests behavior (gateway returns the right tuple; controller returns the right HTTP response), not line numbers. The PRD's AC-015-3 line-number references are preserved as a citation of the current implementation; if the controller is refactored, the test still passes. |

---

## 11. Design Readiness Scorecard

| Dimension | Score | Notes |
|---|---|---|
| Architecture completeness | 4.0 | Components, interfaces, and data flows defined; telemetry emission point codified (§2d); AMB resolutions recorded in §3; alternatives considered and one rejected with rationale |
| Task coverage | 4.0 | Every REQ has at least one implementation task and one test task; PRD ACs mapped via §6 matrix; orphaned annotations: 0; uncovered REQs: 0 |
| Dependency clarity | 4.0 | Every task has explicit `[depends:]` annotations; graph is acyclic; critical path is 5 tasks long; no circular dependencies |
| Estimate confidence | 3.0 | AMB-004's architectural risk is resolved by the `active_run_reservations` map + `ProjectRunReserved` event protocol (race-safe via serialized state, not a fresh query). 24 implementation + 24 test tasks across 4 PRs total 89.5h (PR 1 = 31h, PR 2 = 27h, PR 3 = 11h, PR 4 = 20.5h). Largest single task is TRD-001 (4h); all tasks are 0.5-4h. Reconciler + facade architectural surface is non-trivial; if the reservation-map invariants need additional hooks during PR 2, re-estimation is required. AC-003-4 coverage was expanded in v1.0.3 to include the actor retry-exhaustion contract (TRD-024 + TRD-024-TEST, +2h) and the controller 409 mapping (TRD-007 +1h, TRD-007-TEST +1h), bringing the total from 85.5h to 89.5h. |
| **Overall** | **3.4** | v1.0.1 amendment doubles the architectural surface (reconciler + facade + reservation map + admission-facade-bypass test + 2 new events + extended terminal events). The added rigor closes 12 BLOCKER advisories but raises coordination cost across 4 PRs. v1.0.3 adds actor retry-exhaustion contract (TRD-024 + TRD-024-TEST) and the 409 `version_conflict` mapping (TRD-007 / TRD-007-TEST) — the AC-003 coverage expansion is local to PR 2 and does not change architectural surface area. Advance to 4.0 after: (a) PR 1's `active_run_reservations` map is implemented and the facade-bypass test is green (proves call-graph acyclic invariant); (b) PR 2's reconciler scheduled + subscribed paths converge on the same authoritative state (no behavioral drift); (c) PR 2's actor retry-exhaustion tuple is verified end-to-end against the controller 409 mapping (no behavioral drift between actor contract and HTTP response). AMB-004 and AMB-005 are resolved in this TRD (§3); AMB-001 and AMB-003 remain operational. |

**Gate verdict:** CONCERNS (3.0-3.9 on the dependency-clarity × estimate-confidence axis; 4.0 on the others). User has approved proceeding with AMBs resolved at TRD stage (per the Phase 1 readiness-gate user response 2026-08-07). Implementation may proceed against this TRD with the following constraint:

- **AMB-001 / AMB-003** are operational questions, not code questions; they remain open and do not block implementation.
- **AMB-004** must be verified at the start of TRD-011 (the `run_start_payload` schema check that the predicate relies on is documented as an explicit implementation AC, not a hidden step).
- **AMB-005** is resolved in §3 (configurable cap, default 1000).

---

## 12. Reused Capabilities

None. The capability registry (`node trd-graph-cli.js capabilities docs/TRD`) returns an empty list; `trd-graph-cli.js overlap docs/TRD` reports no target-file overlap with the existing foundational TRDs. The project CRUD surface does not reuse any capability from the four existing TRDs (`foreman-beads-task-provider`, `otp-agent-runtime`, `go-elixir-cqrs-parity`, `go-elixir-cqrs-parity-gaps`).

---

## 13. Changelog

| Version | Date | Changes |
|---|---|---|
| 1.0.0 | 2026-08-07 | Initial TRD generated from PRD-2026-002184c6 v0.1.4. 16 implementation tasks + 16 paired test tasks across 3 PRs (server foundation, HTTP read routes, CLI + exit codes + docs). 50.5h total. AMB-004 and AMB-005 resolved at TRD stage (§3); AMB-001 and AMB-003 deferred to operational baseline observation. Architecture self-critique (4 issues), task coverage analysis (3 issues), dependency review (2 issues), testability review (2 issues) documented in §7-§10. Design Readiness Scorecard: 3.75 CONCERNS — user-approved to proceed (Phase 1 readiness-gate confirmation 2026-08-07). |
| 1.0.1 | 2026-08-07 | Architectural amendment addressing 12 BLOCKER advisories raised during PRD/TRD refinement. AMB-004 (active-run check) replaced with event-sourced saga: `Project.State.active_run_reservations :: Map.t(String.t(), {command_id, project_id, sequence, run_start_payload})` keyed by `run_id`; `ProjectRunReserved` / `ProjectRunReservationReleased` events carry `run_start_payload` for retry; `Run.State.project_id` populated on `RunStarted` apply + rehydration test; terminal events extended with `project_id` + `run_id`. Router-owned admission path: `RunAdmission.start/2` (public facade) → `CommandRouter.dispatch_run_start/2` (internal-but-public, allowlist = `run_admission.ex` only) → `defp do_dispatch/2` (private protocol). `RunLifecycleReconciler` uses retry-not-release protocol on absence; subscription path reads `project_id` from terminal event payload (no `run_projection/1`); scheduled path uses `Run.load/Project.load` and re-dispatches via `RunAdmission.start/2`. 4-PR breakdown: Active-Run Tracking → Mutations+Telemetry+Admission → HTTP Read → CLI. 23 impl + 23 test = 46 tasks, 85.5h total. Self-critique expanded to A1-A10 (added A5 sentinel, A6 compensable-error allowlist, A7 terminal-event project_id, A8 reconciler authoritative source, A9 MapSet discards retry metadata, A10 retry-not-release TOCTOU). Design Readiness Scorecard revised 3.75 → 3.4 CONCERNS. |
| 1.0.2 | 2026-08-07 | Architecture-prose stale-reference audit (Advisory 14) — closes a residual gap where §2/§3/§7/§8/§10 still contained v1.0.0 task IDs and architectural patterns rejected by v1.0.1. **§2a data flow:** removed `admission: :reserved` sentinel and `ProjectionStore.run_projection(run_id)` (replaced with terminal-event payload for subscription path; `Run.load/Project.load` for scheduled path). **§2a list endpoint:** clarified `X-Total-Count` exposes the **underlying full count** of matching rows (NOT truncated body length) — unifies semantics with TRD-015, tests, and Sprint 3. **§2b diagram:** re-routed edges to drop the `admission: :reserved` label and the `run_projection/1` resolution edge; added `RLR → RA` retry edge for scheduled-pass orphan-recovery. **§2d telemetry:** corrected `:orphan_released` → `:orphan_retry` in line 134 (`telemetry.ex` row) to match §2d table. **§3 AMB-005:** explicit allowlist (default 1000, configurable via `:projects_list_max`). **§7 A1/A3/A4:** race-safety clarified; `run_start_payload` schema risk flagged in D1. **§8 C1/C2/C3:** REQ-007 split across TRD-014/TRD-015; REQ-011 regression-safe via TRD-016; REQ-003 (201 envelope) regression guard moved into TRD-016-TEST (not TRD-001-TEST). **§10 T1/T2:** line-number references preserved as citations, tests bound to behavior. **§6 traceability footer:** 62 explicit / 16 implicit AC reconciliation. **Total hours:** 85.5h (unchanged). |
| 1.0.3 | 2026-08-07 | AC-003 coverage expansion (Advisory 15, 6 BLOCKER advisories addressed). **TRD-007 expanded 2h → 3h:** title now "Update `command_controller.ex` allowlist tables + 409 version-conflict mapping for `project.update` and `project.archive`"; added 2 implementation ACs (201 envelope shape regression guard for update/archive; 409 `version_conflict` mapping with `current_version` propagated from the actor's retry-exhaustion tuple — NOT a projection lookup per §3/§7 A8). **TRD-007-TEST expanded 1h → 2h:** title now "Controller allowlist + HTTP mutation envelope + 409 mapping tests"; added 3 new test cases (HTTP 201 envelope for `project.update`, HTTP 201 envelope for `project.archive`, 409 `version_conflict` mapping with `code:` field per PRD AC-003-4); `depends:` updated to `TRD-007, TRD-008`. **TRD-024 (new, 1h) + TRD-024-TEST (new, 1h)** added at end of PR 2: actor retry-exhaustion contract extension — propagates `current_version` (the actor's stream version at exhaustion, reloaded via generic `Aggregate.load/2` per AGENTS.md) in the returned `{:error, {:wrong_expected_version, current_version}}` tuple. TRD-024-TEST verifies the real `Aggregate.Actor` (no mocks) emits the tuple — injects sustained `wrong_expected_version` failures, forces retry exhaustion, asserts the returned tuple matches the actor's stream version via `:sys.get_state/1`. **§4 cross-PR graph:** prose graph strictly aligned with task-level `Depends on:` annotations (previously over-claimed edges that the annotations did not support — e.g., `TRD-002 → TRD-003`, `TRD-005 → TRD-011`, `TRD-001/002 → TRD-007`). Added `TRD-001 → TRD-024 → TRD-024-TEST` dependency edge (TRD-007-TEST explicitly stubs the gateway and does NOT depend on TRD-024 — its `[depends:]` annotation is `TRD-007, TRD-008`). **§4 critical path:** recomputed from `Depends on:` annotations — three chains tie at **5 implementation tasks** `(a) TRD-001 → TRD-002 → TRD-004 → TRD-005 → TRD-013`, `(b) TRD-001 → TRD-002 → TRD-004 → TRD-006 → TRD-013`, `(c) TRD-001 → TRD-002 → TRD-011 → TRD-020 → TRD-023` (the cross-PR chain). The earlier draft claim of "8 tasks" was wrong: TRD-003 has no deps so `TRD-002 → TRD-003` is not an edge; TRD-011 depends only on TRD-001/TRD-002 so `TRD-005 → TRD-011` is not an edge. The 5-task figure matches the §11 Dependency clarity scorecard. TRD-024 + TRD-024-TEST are a 3-node parallel branch off TRD-001 (does NOT extend main critical path). **§5 Sprint 2:** `~23h` → `~27h`; added bullet describing the controller → actor retry-exhaustion contract mapping. **§6 REQ-003 row:** cites TRD-007-TEST (AC-003-2/3/4 envelope + 409 mapping) + TRD-024-TEST (AC-003-4 actor contract) + TRD-016-TEST (AC-003-1 register regression). **§8 C3 row:** expanded — AC-003-1 in TRD-016-TEST, AC-003-2/3 in TRD-007-TEST, AC-003-4 layered across TRD-007-TEST (controller rendering) + TRD-024-TEST (real actor contract). **Task estimate summary:** 48 tasks, 89.5h total (PR 2 = 27h). **§11 Estimate confidence:** reflects +4h net (TRD-024 +1h, TRD-024-TEST +1h, TRD-007 +1h, TRD-007-TEST +1h). **Traceability:** 66 explicit / 12 implicit AC. **Not changed by v1.0.3:** §2 architecture, §3 AMB resolutions, §7 A1-A10 self-critique, §9 D1/D2, §10 T1/T2. |
| 1.0.4 | 2026-08-07 | §4 cross-PR graph strict-alignment correction (Advisory 16, two BLOCKER advisories addressed). **§4 prose graph** (lines 732-763) now strictly mirrors the task-level `Depends on:` annotations. Edges that were over-claimed and removed: `TRD-001, TRD-002 → TRD-003` (TRD-003 has no deps), `TRD-001, TRD-002 → TRD-007` (TRD-007 has no deps — first task in PR 2), `TRD-001, TRD-002 → TRD-010` (TRD-010 depends only on TRD-007), **`TRD-007 → TRD-009` (TRD-009 has no deps — web-layer CQRS test allowlist runs in parallel with TRD-007)**, `TRD-005 → TRD-011` (TRD-011 depends only on TRD-001, TRD-002), `TRD-001, TRD-004 → TRD-005` (TRD-005 actually depends on TRD-001, TRD-002, TRD-003, TRD-004), `TRD-015 → TRD-021` (TRD-021 depends on TRD-015 AND TRD-022). Edges corrected: `TRD-005 → TRD-013` now correctly shows `TRD-005, TRD-006 → TRD-013`; `TRD-021 → TRD-023` now correctly shows `TRD-015, TRD-022 → TRD-021`. **§4 critical path** recomputed strictly from task annotations: three chains tie at **5 implementation tasks** — `(a) TRD-001 → TRD-002 → TRD-004 → TRD-005 → TRD-013` (PR 1 only), `(b) TRD-001 → TRD-002 → TRD-004 → TRD-006 → TRD-013` (PR 1 only), `(c) TRD-001 → TRD-002 → TRD-011 → TRD-020 → TRD-023` (the cross-PR chain). The v1.0.3 changelog claim of "8 tasks" was wrong — corrected inline. Matches the §11 Dependency clarity scorecard claim ("critical path is 5 tasks long"). **Realigned by v1.0.4:** §13 v1.0.3 changelog entry — the critical-path claim was corrected from "8 tasks" to "5 tasks" to match the recomputed longest chain. **Unchanged by v1.0.4:** §1-§3, §5-§12, §13 v1.0.0/v1.0.1/v1.0.2 changelog entries, task hours (89.5h), task count (48), graph semantics. The TRD remains at CONCERNS (3.4) and is ready for Phase 1 readiness-gate review with corrected graph documentation. |
