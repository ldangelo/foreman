---
document_id: TRD-2026-81315f37
label: trd-atomic-beads-task-create-and-watcher
version: 1.0.7
status: Draft
date: 2026-08-11
prd_reference: docs/PRD/PRD-2026-81315f37-atomic-beads-task-create-and-watcher.md
prd_label: prd-atomic-beads-task-create-and-watcher
scale_depth: STANDARD
total_requirements: 7
total_acceptance_criteria: 30
total_tasks: 31
design_readiness_score: 4.0
readiness_score: 4.0
kind: trd
---

# TRD: Atomic Beads Task-Create and JSONL Watcher

## 1. Executive Summary

This TRD turns PRD `PRD-2026-81315f37-atomic-beads-task-create-and-watcher` (v1.0.5, readiness 4.0, 7 REQs, 30 ACs) into a concrete implementation plan for the synchronous `task.create` ↔ Beads Rust `br create` linkage slice. The PRD micro UUID `81315f37` is preserved across artifacts so PRD/TRD pairs correlate 1:1. The label prefix changes from `prd-` to `trd-` (`trd-atomic-beads-task-create-and-watcher`); the label is display-only and all cross-references use the micro UUID.

The implementation lives under `packages/foreman_server/` (the Fortium foreman repo's existing Phoenix package — paths in this TRD are package-relative). The slice is supervised by the existing `ForemanServer.Application` supervisor tree; the new supervisor(s) are children, not a parallel OTP application.

The TRD delivers, in three vertical slices:

1. **PR 1 — `TaskProvider` behaviour extension + `BeadsAdapter.create/2` + `SystemBrRunner` `:create` support** (6 implementation tasks + 6 paired test tasks). The `TaskProvider` behaviour gains the `create/2` callback (callback count 11 → 12); `BeadsAdapter.create/2` is implemented with `--agent-context` JSON carrying the Foreman tag; 5 new CodeMap rows cover `br create` failure modes; the capability list advertises `:create`; `SystemBrRunner` gains a dedicated `:create` clause in `build_action_argv/2` with validate-first ordering. The synchronous Actor hook is NOT yet wired — the Actor still produces a `TaskCreated` event with `external_id: nil` at the end of PR 1.
2. **PR 2 — Actor two-stage finalization + in-flight cache + boundary invariant** (4 implementation + 4 paired test). The Actor's `do_dispatch/4` runs a two-stage aggregate finalization for `task.create` (stage 1 validate; stage 2 `BeadsAdapter.create/2` I/O; stage 3 re-decide with `external_id` enriched; stage 4 normalize + append). The `in_flight_beads: %{command_id => bead_handle}` cache lives on Actor state and prevents two `br create` invocations for the same logical command. `CommandGateway.dispatch_operator/2` rejects `task.create` envelopes with non-nil `payload.external_id`; `dispatch_system/2` is unchanged and remains the trusted path for the watcher-import branch.
3. **PR 3 — JSONL watcher + orphan janitor + opt-in supervision + docs** (5 implementation + 5 paired test + 1 docs). `BeadsWatcher` tails `.beads/issues.jsonl` per registered project, with boot replay + tail mode under a 3-way cursor priority (single-cursor invariant). `BeadsOrphanJanitor` periodically scans for foreman-tagged orphans. Both are opt-in via `:start_beads_watcher?` / `:start_beads_orphan_janitor?` (default `false`). The `ProjectionStore` `TaskCreated` handler stores `external_id`. Docs (`docs/user-guide.md`, `docs/cli-reference.md`, `README.md`, `CLAUDE.md`) are updated per the `foreman-doc-gate` skill.

The slice is intentionally bounded: it integrates new modules into the aggregation pipeline (`TaskCreated` projection, Actor hook, CommandGateway boundary, opt-in supervisor children) but does not migrate any existing functionality. Existing Task/Run/Project aggregates that do not opt into `task_provider` continue to operate exactly as before.

**Central commitments:**

- **Compensating consistency, not true atomicity.** The in-process synchronous hook delivers synchronous all-or-nothing for the normal path (`br create` failure returns the provider error and produces no `TaskCreated` event); the orphan janitor (REQ-023) absorbs the residual gap from Actor crashes and failed-compensation paths within a configurable grace window (default 300s).
- **Single-event design.** The bead-linkage signal rides entirely on `TaskCreated.external_id` (an existing optional field). The aggregate stays pure throughout — the Actor enriches the COMMAND payload with `external_id` and re-runs `handle_command/2` so the aggregate emits the enriched event itself. The Actor never fabricates events or merges fields into event specs. No `EventCodec` re-registration is required because no new typed event is introduced.
- **CommandGateway boundary invariant.** `dispatch_operator/2` rejects `task.create` envelopes with non-nil `payload.external_id` at the existing envelope allowlist guard; `dispatch_system/2` is unchanged and remains the trusted path for the watcher-import branch. The invariant is enforced once at the boundary; the Actor does not duplicate the origin check.

**Total task count: 31 entries** (15 implementation tasks + 15 paired test tasks + 1 docs-only task). Implementation + paired test for the 6 docs-eligible areas is the smallest correct shape; the 1 docs-only task (`TRD-015-TASK`) covers the user-guide / cli-reference / README / CLAUDE.md updates per the `foreman-doc-gate` skill.

---

## 2. Architecture Decision

### 2.1 Options Considered

The PRD frames the work as "synchronous in-process all-or-nothing for the normal path with compensating recovery for the residual gap." Three architectural approaches were considered for the write-side (`task.create` → Beads bead creation):

#### 2.1.1 Option A — Asynchronous bridge

A `BeadsBridge` supervisor subscribes to `TaskCreated` events from the projection stream. On each `TaskCreated` (with `external_id: nil`), the bridge dispatches a side-channel `br create` call asynchronously and updates the projection with the resulting bead ID via a separate event.

- **Pros:** The Actor path stays untouched (no I/O inside the dispatcher); a single failure mode (bridge crash) is contained; the existing `TaskCreated` event shape is unchanged.
- **Cons:** Two stores can disagree for arbitrarily long windows — the user sees a Foreman task with `external_id: nil` until the bridge catches up. There is no in-process "I just dispatched a `task.create`; the bead now exists" guarantee. Operator UX degrades because the bead ID is not immediately available after a CLI invocation.
- **Complexity impact:** Lowest at the integration boundary (no Actor change); highest at the consistency boundary (eventual consistency spans the bridge latency).
- **Risk profile:** A bridge backlog is a correctness bug — beads can be created much later than the user expects, and the projection map will surface a `nil` `external_id` in the interim. Lost bridges (e.g. bridge crash with no replay) are stranded beads that no janitor can recover (the bridge never recorded the bridge's own pending list). Tagged with `risk: HIGH` for the user-facing inconsistency window.

#### 2.1.2 Option B — Standalone reconciler

A `BeadsReconciler` GenServer periodically (every N seconds) scans the projection store for tasks with `external_id: nil` and dispatches `br create` for each, with the bead ID landing as a `TaskBeadLinked` event on a separate stream. The reconciler is the sole bead-creation path.

- **Pros:** All bead creation is funneled through one component; the reconciler is a natural place to centralise rate-limiting, retry, and audit logging; the Actor path is unchanged.
- **Cons:** Latency between `task.create` and bead materialization is at minimum the reconciler period (default 30s, configurable). Operator CLI returns a task ID but not a bead ID — the bead appears minutes later. A second event (`TaskBeadLinked`) is required, which violates the slice invariant ("every emitted event is owned by an aggregate's `handle_command/2`; no module fabricates events"). Two new typed events and two new operator types are required.
- **Complexity impact:** High — new event types, new projection handler, new operator type allowlist extension, new architecture-test enforcement.
- **Risk profile:** A reconciler crash is recoverable (the next scan picks up the backlog), but the in-process hook guarantee is permanently sacrificed. The slice invariant is violated; downstream architecture tests must be amended to allow `TaskBeadLinked` as a non-aggregate-emitted event, weakening the invariant's value. Tagged with `risk: HIGH` for the invariant violation.

#### 2.1.3 Option C — Two-stage aggregate finalization in the Actor hook (CHOSEN)

The Actor's `do_dispatch/4` runs a two-stage aggregate finalization for `task.create`:

- **Stage 1 (validate, pure):** `aggregate.handle_command(state, original_cmd)` returns `{:ok, %{event_type: "TaskCreated", payload: %{...external_id: nil...}}}` or `{:error, _}`. No I/O.
- **Stage 2 (Beads I/O):** If stage 1 returned `{:ok, _}` AND the project has Beads-management enabled with `:create` in `capabilities.supports` AND `cmd.payload.external_id` is `nil` (atom key), the Actor invokes `BeadsAdapter.create/2`. On `{:error, %ProviderError{}}` the Actor returns the error from `do_dispatch/4` — no event is emitted. On `{:ok, %TaskProvider.Issue{id: bead_id}}` the Actor stores `bead_id` in `state.in_flight_beads[command_id]`.
- **Stage 3 (re-decide, pure):** The Actor enriches the command payload with `:external_id = bead_id` and calls `aggregate.handle_command/2` again, which deterministically produces `event_spec.payload.external_id == bead_id`.
- **Stage 4 (existing Actor↔CommandRouter append/ack protocol — NOT a direct `EventStore` call):** the Actor's existing protocol is the SOLE append point in the codebase (per the architecture test enforcing `CommandRouter` as the sole `EventStore.append_to_stream` caller). The Actor sends `{:append, aggregate_id, [event_data], expected_version, ref, self()}` to `CommandRouter`; `CommandRouter` calls `EventStore.append_to_stream/3` and replies with `{:append_ok, ref, count, append_latency_ms}` (or `{:error, ref, reason, append_latency_ms}`). On `{:append_ok, _, _, _}` the Actor calls `commit_event/3` (which calls `aggregate.apply_event/2` and bumps `state.version`) AND clears `state.in_flight_beads[command_id]`. On `{:error, ^ref, :wrong_expected_version, _}` with `retries_left > 0` the Actor calls `reload_after_conflict/1` (which preserves `in_flight_beads` via `%{state | module_state: …, version: …}`) and recurses through `do_dispatch/4`. The recursive call re-runs `handle_command/2` (re-decide with cached `external_id` in stage 3) and re-sends to `CommandRouter` — NO additional `BeadsAdapter.create/2` invocation.

The slice invariant ("every emitted event is owned by an aggregate's `handle_command/2`; no module fabricates events") is preserved end-to-end: the Actor enriches the COMMAND payload, not the event spec, and the aggregate emits the enriched event on the second `handle_command/2` invocation.

- **Pros:** The in-process hook delivers synchronous all-or-nothing for the normal path (AC-020-1 happy path; AC-020-5 failure path — no `TaskCreated` event is emitted when `br create` fails). The bead ID is available on the projection immediately after a successful create. The slice invariant is preserved. No new typed event, no new operator type, no codec re-registration. The orphan janitor (REQ-023) closes the residual gap (Actor crash between `br create` success and append confirmation, or compensation `br close` failure) within a configurable grace window.
- **Cons:** Every `task.create` now waits on `br create` (bounded by the per-call timeout from `PRD-2026-48f7b420` REQ-009 — 30s default). The synchronous hook is a single point of latency. An Actor crash between `br create` success and append confirmation is a recovery problem (the orphan janitor absorbs the strander on its grace-window scan).
- **Complexity impact:** Medium at the Actor hook (two-stage finalization in `do_dispatch/4`, in-flight cache, compensation path); low at the projection layer (1-line addition of `external_id` to the existing `TaskCreated` handler); medium at the supervision layer (two new opt-in children).
- **Risk profile:** The synchronous latency is bounded and observable; the compensation path (AC-020-3) handles append-conflict failures; the orphan janitor (REQ-023) handles cron-drop cases. Tagged with `risk: MEDIUM` for the latency profile, mitigated by the documented compensation + janitor safety net.

### 2.2 Chosen Architecture: Option C — Two-Stage Aggregate Finalization

The chosen architecture is **Option C: Two-stage aggregate finalization in the Actor hook**. The decision is justified by the PRD's compensating-consistency requirement (REQ-020) and the slice invariant ("every emitted event is owned by an aggregate's `handle_command/2`"). Option A sacrifices the in-process guarantee and risks a long inconsistency window; Option B violates the slice invariant by introducing a non-aggregate-emitted event. Option C is the smallest correct fix that delivers synchronous all-or-nothing for the normal path while preserving the invariant end-to-end.

#### 2.2.1 Component Boundaries

The new components and the modules they integrate with:

| Component | Path | Responsibility |
|---|---|---|
| `ForemanServer.TaskProvider` (behaviour) | `lib/foreman_server/task_provider.ex` | Declare the new `@callback create/2` (callback count 11 → 12) |
| `ForemanServer.TaskProviders.BeadsAdapter` | `lib/foreman_server/task_providers/beads_adapter.ex` | Implement `create/2`; extend `capabilities/0` to advertise `:create`; construct `--agent-context` JSON; route `br create` failure modes through `CodeMap` |
| `ForemanServer.TaskProviders.BeadsAdapter.CodeMap` | `lib/foreman_server/task_providers/beads_adapter_code_map.ex` | Add 5 new rows: `INVALID_TITLE`, `INVALID_PRIORITY`, `INVALID_ISSUE_TYPE`, `DUPLICATE_TASK_ID`, `CREATE_FAILED` (fallback) |
| `ForemanServer.TaskProviders.BeadsWatcher` | `lib/foreman_server/task_providers/beads_watcher.ex` (new) | Supervised GenServer; one tail process per registered project; boot replay + tail mode with single-cursor invariant (3-way cursor priority); dispatches synthetic `task.create` via `CommandGateway.dispatch_system/2` with `external_id` pre-populated |
| `ForemanServer.TaskProviders.BeadsOrphanJanitor` | `lib/foreman_server/task_providers/beads_orphan_janitor.ex` (new) | Supervised GenServer; one scanner per registered project; first scan after grace window; closes foreman-tagged orphans with `transition_comment: "foreman-orphan:no-task"` or `"…terminal-task"` |
| `ForemanServer.Aggregate.Actor` | `lib/foreman_server/aggregate/actor.ex` | Extend state with `in_flight_beads: %{command_id => bead_handle}`; insert two-stage finalization in `do_dispatch/4` (stage 1 validate; stage 2 `BeadsAdapter.create/2`; stage 3 re-decide; stage 4 normalize + append); compensation path on append-conflict |
| `ForemanServer.CommandGateway` | `lib/foreman_server/command_gateway.ex` | Extend `dispatch_operator/2` envelope allowlist guard to reject `task.create` with non-nil `payload.external_id` (return `{:error, :external_id_not_allowed_via_operator}`); `dispatch_system/2` is unchanged and remains the trusted path for the watcher-import branch |
| `ForemanServer.ProjectionStore` | `lib/foreman_server/projection_store.ex` | Extend `apply_event_by_type(state, "TaskCreated", payload)` to include `external_id` in the task map (default `nil` for legacy events) |
| `ForemanServer.Application` | `lib/foreman_server/application.ex` | Add `maybe_beads_watcher_child/0` and `maybe_beads_orphan_janitor_child/0` (mirrors `maybe_json_schema_cache_child/0` / `maybe_project_provider_projector_child/0`); opt-in via `:start_beads_watcher?` / `:start_beads_orphan_janitor?` config flags (default `false`) |
| `ForemanServer.TaskProvider.Registry` | `lib/foreman_server/task_providers/registry.ex` | Update `route/2` (line 69) to dispatch `:create` to the same per-project state; `register_for_project/3` likely needs no change |
| `ForemanServer.EventCodec` | `lib/foreman_server/event_codec.ex` | NO changes; `external_id` is an existing optional field on `Events.TaskCreated` so no re-registration is required |

The new modules are supervised by the existing `ForemanServer.Application` supervisor tree. No new OTP application is introduced.

#### 2.2.2 Data Flow — Synchronous Hook (Operator-Driven `task.create`)

```
Operator (Go CLI) — `foreman task create --project-id <id> --title <t> --priority <p> --type <ty> --description <d>`
  │
  ▼
Phoenix POST /api/commands  (existing boundary)
  │
  ▼
CommandGateway.dispatch_operator/2  (envelope allowlist guard)
  │   ▲
  │   └── REJECT: {:error, :external_id_not_allowed_via_operator} if payload.external_id != nil
  │         (AC-020-7 boundary invariant)
  ▼
CommandRouter.dispatch(command)  (existing; dedup by command_id)
  │
  ▼
Aggregator.start_aggregate(module, id)  (existing; supervised; restart: :permanent)
  │
  ▼
Actor.do_dispatch/4  (TWO-STAGE FINALIZATION)
  │
  │   Stage 1 (validate, pure):
  │     aggregate.handle_command(state, original_cmd)
  │     → {:ok, %{event_type: "TaskCreated", payload: %{...external_id: nil...}}}
  │     → {:error, _} (e.g. {:already_exists, :task, task_id}) — return error, no event
  │
  │   Per-project gate:
  │     IF cmd.payload.external_id is nil
  │        AND BeadsAdapter.capabilities().supports has :create
  │        AND state.in_flight_beads[command_id] is NOT present
  │     THEN stage 2
  │
│   Stage 2 (Beads I/O):
│     BeadsAdapter.create(project_id, attrs)   where attrs is the canonical seven-key map (see Architecture Decision #12)
│       attrs shape: %{task_id :: String.t(), command_id :: String.t(), title :: String.t(),
│                      description :: String.t() | nil, priority :: non_neg_integer(),
│                      task_type :: String.t(), dedupe_key :: String.t() | nil}
│       internal: TaskProvider.Registry.project_config(project_id) → {:ok, %{config: %{database_path: db_path}}}
│                                            or {:error, reason} → return CREATE_FAILED (AC-020-5; terminal; no br create)
│       internal: pre-emptive Foreman-side validation (reject missing title / out-of-range priority / out-of-enum task_type
│                                            / missing task_id or command_id) BEFORE constructing argv (TRD-003 Action #3)
│       transform: attrs → runner-payload  (TRD-003 Action #5; runs after pre-emptive validation, before BrRunner.cmd/3)
│                                            (1) :task_type → :type rename (the ONLY key rename; matches `br create --type`)
│                                            (2) :description nil → "" normalization (the ONLY nullable field)
│                                            (3) :agent_context = Jason.encode!(%{foreman: %{task_id: attrs.task_id,
│                                                command_id: attrs.command_id, origin: "foreman",
│                                                linked_at: iso8601_utc_now()}}) — constructed from canonical attrs
│                                                correlation handles; never accepted from caller
│                                            (4) :title → :title, :priority → :priority passthrough
│                                            (5) :task_id / :command_id / :dedupe_key preserved on canonical attrs but
│                                                do NOT enter the runner-payload (correlation / future-extension only)
│       call: BrRunner.cmd({:create, payload}, project_config, opts)  where payload is the runner-payload (NOT attrs;
│                                  Decision #14 defines it as a SUBSIDIARY of Decision #12's canonical attrs) and
│                                  project_config = %{database_path: db_path} (from Registry.project_config/1; Decision #13).
│                                  SystemBrunner owns ALL argv construction (Decision #14); the dedicated :create clause
│                                  in build_action_argv/2 validates the payload shape FIRST then emits:
│       argv: br create --title <payload.title> --type <payload.type> --priority <payload.priority-as-string>
│             --description <payload.description>          (payload.description is "" when attrs.description was nil)
│             --agent-context <payload.agent_context>      (payload.agent_context is the Jason.encode!(...) JSON string
│                                                              constructed in the transform step above)
│             --db <db_path> --json   (db_path resolved via Registry.project_config/1; TRD-005)
│     → {:ok, %TaskProvider.Issue{id: bead_id}}  ─ store in state.in_flight_beads[command_id]
│     → {:error, %ProviderError{code: _, retryable?: _, ...}}  ─ RETURN error from do_dispatch/4
│         (AC-020-5 failure-as-error contract; telemetry [:create, :failure]; NO event emitted)
  │
  │   Stage 3 (re-decide, pure):
  │     aggregate.handle_command(state, %{original_cmd | payload: Map.put(original_cmd.payload, :external_id, bead_id)})
  │     → {:ok, %{event_type: "TaskCreated", payload: %{...external_id: bead_id...}}}  (deterministic)
  │
  │   Stage 4 (Actor↔CommandRouter append/ack protocol — NOT a direct EventStore call):
  │     event_data = normalize_to_event_data(event_spec)
  │     send CommandRouter, {:append, aggregate_id, [event_data], expected_version, ref, self()}
  │     receive {:append_ok, ^ref, count, append_latency_ms}
  │       → commit_event(state, event_spec, append_latency_ms)  (call apply_event/2; bump state.version)
  │       → clear state.in_flight_beads[command_id]
  │     receive {:error, ^ref, :wrong_expected_version, _}  with retries_left > 0
  │       → reload_after_conflict/1 (preserves in_flight_beads via %{state | module_state: …, version: …})
  │       → recursive do_dispatch/4 (re-runs handle_command/2 with cached external_id; NO second br create)
  │     Bounded retry exhaustion or post-reload re-decision rejection → compensation path (AC-020-3); see §2.2.4
  │
  ▼
CommandRouter returns :ok to the caller
```

The Actor's `in_flight_beads` cache prevents two `br create` invocations for the same logical command (initial dispatch + `reload_after_conflict` retry). On a retry, the Actor consults the cache first; on cache hit, stage 2 is skipped and the cached `bead_id` is reused in stage 3.

#### 2.2.3 Data Flow — Watcher-Import Branch (System-Issued `task.create`)

The watcher's synthetic `task.create` envelope carries a pre-populated `external_id` and routes through `CommandGateway.dispatch_system/2` (the trusted system path):

```
BeadsWatcher tail process  (BeadsWatcher.read_more/1)
  │
  ▼
For each new JSONL line:
  │   parse JSON
  │   IF agent_context.foreman present → skip (emit [:watcher, :skipped])
  │   ELIF ProjectionStore.get_task(external_id: bead.id) hits → reconcile (emit [:watcher, :reconciled])
  │   ELSE → dispatch:
  │     envelope = %{
  │       command_id: "beads-cmd:" <> project_id <> ":" <> bead_id,  (deterministic)
  │       aggregate_id: "task:" <> task_id,
  │       payload: %{
  │         external_id: bead.id,
  │         title: bead.title,
  │         description: bead.description,
  │         priority: bead.priority,
  │         task_type: bead.issue_type,
  │         project_id: project_id
  │       }
  │     }
  ▼
CommandGateway.dispatch_system/2  (trusted; not rejected)
  │
  ▼
CommandRouter.dispatch → Actor.do_dispatch/4
  │
  │   Stage 1 (validate, pure):
  │     aggregate.handle_command(state, original_cmd)
  │     → {:ok, %{event_type: "TaskCreated", payload: %{...external_id: bead_id...}}}  (already populated)
  │
  │   Per-project gate detects pre-populated external_id:
  │     SKIP stage 2 (no br create — bead already exists in .beads/issues.jsonl)
  │     Telemetry: [:foreman_server, :task_provider, :beads, :create, :skipped_watcher_import]
  │
  │   Stage 4 (Actor↔CommandRouter append/ack protocol — pre-populated external_id, no I/O): stage-1 event_spec passes through unchanged; Actor sends {:append, …} to CommandRouter and commits on {:append_ok, …}; nothing in the in-flight cache for this command_id (skill 2 was skipped).
  ▼
CommandRouter returns :ok
```

The watcher-import branch uses the same single-event linkage path as the operator-driven case: `TaskCreated.payload.external_id == bead_id` is the linkage; no second event is emitted.

#### 2.2.4 Error Paths and Recovery

| Failure | Detection Point | Recovery |
|---|---|---|
| `CommandRouter` returns `{:error, ^ref, :wrong_expected_version, _}` to Actor (cache hit; pre-append conflict) | Stage 4 (compensation path) | Actor consults `state.in_flight_beads[command_id]`; on hit, calls `reload_after_conflict/1` (preserves the cache via `%{state | module_state: …, version: …}`), re-runs `do_dispatch/4` which re-runs stage 3 with the cached `external_id` and re-sends to `CommandRouter`. NO `br close` and NO cache clear on transient retry. (AC-020-3, AC-024-1) |
| Bounded retry exhaustion (`@max_conflict_retries` reached) or post-reload re-decision rejection | Stage 4 (compensation terminal) | Actor calls `BeadsAdapter.complete(project_id, bead_id, %{transition_comment: "foreman-compensation:append-conflict-retry-exhausted"})` (or `"…re-decision-rejected"` respectively) — this is subprocess I/O, NOT a `CommandRouter` event; emits `[:create, :compensated]`, clears the cache entry, returns the error from `do_dispatch/4`. (AC-020-3, CLOSE-ONLY-ONCE) |
| Compensation `br close` itself fails | Stage 4 (compensation failure) | Actor emits `[:foreman_server, :task_provider, :beads, :create, :compensate_failure]`. The orphan janitor (REQ-023) takes over on its next grace-window scan. |
| Actor crashes after `br create` returns success but before receiving `{:append_ok, …}` from CommandRouter | Actor supervisor restart | Cache is process-local and does NOT survive the crash. Orphan janitor (REQ-023) closes the strander on its grace-window scan (default 300s). (AC-024-3) |
| Watcher dispatch returns `{:ok, _}` (terminal) | Watcher `read_offset` advance | `read_offset` advances past `byte_size(line) + 1`; next poll reads from the advanced offset. (AC-022-1) |
| Watcher dispatch returns `{:error, {:already_exists, :task, _}}` / `{:error, {:invalid_task_status, _}}` / `{:error, {:project_archived, _}}` / `{:error, :project_id_required}` (terminal — aggregate domain rejections) | Watcher `read_offset` advance | Same as `{:ok, _}` — terminal set is exhaustive per AC-022-1. |
| Watcher dispatch returns transient (`ProviderError{retryable?: true}`, `:wrong_expected_version` after Actor retry, `:exit, :killed`, etc.) | Watcher transient | `read_offset` HOLDS at the transient-line start byte; `partial_line` is the bytes of the FIRST LINE NOT TERMINALLY DISPATCHED; next poll re-reads the held line and re-attempts with the same deterministic `command_id`. (AC-022-1, 3-way cursor priority) |
| Foreman-tagged bead with no corresponding Foreman task after grace window | OrphanJanitor scan | Bead is closed via `BeadsAdapter.complete(project_id, bead_id, %{transition_comment: "foreman-orphan:no-task"})`. Telemetry `[:orphan, :janitor, :closed]`. (AC-023-2) |
| Foreman-tagged bead with corresponding Foreman task in `closed` / `failed` state | OrphanJanitor scan | Bead is closed with `transition_comment: "foreman-orphan:terminal-task"`. Telemetry `[:orphan, :janitor, :closed]`. (AC-023-3) |
| Non-foreman-tagged bead | OrphanJanitor scan | Skipped. Telemetry `[:foreman_server, :task_provider, :beads, :orphan, :janitor, :retained]`. Untouched. (AC-023-4) |

#### 2.2.5 Reused Capabilities

The slice reuses the following existing infrastructure (no new code or contracts; integration only):

- **`ForemanServer.TaskProvider` behaviour** — declares 11 callbacks; extended with `create/2` (callback count 11 → 12 per AC-025-3). The behaviour shape test at `packages/foreman_server/test/foreman_server/task_provider_test.exs:12` and `:24` is updated from `assert length(callbacks) == 11` to `assert length(callbacks) == 12` and adds `assert {:create, 2} in callbacks`.
- **`ForemanServer.TaskProviders.BeadsAdapter`** — existing 8 operational callbacks (list_ready, get, claim, complete, fail, reopen, set_priority, add_dependency) remain unchanged. `create/2` is added as a 9th operational callback. `capabilities/0` is extended to advertise `:create` (AC-025-2).
- **`ForemanServer.TaskProviders.BeadsAdapter.CodeMap`** — the existing 8-key allowlist for `ProviderError.context` is unchanged; 5 new rows are added for `br create` failure modes (AC-026-1 through AC-026-5). All new rows reuse the existing context shape (no new keys).
- **`ForemanServer.CommandGateway.dispatch_operator/2`** — existing envelope allowlist guard; extended at the allowlist guard to reject non-nil `payload.external_id` (AC-020-7) with `{:error, :external_id_not_allowed_via_operator}`. `dispatch_system/2` is unchanged and remains the trusted path for the watcher-import branch.
- **`ForemanServer.Aggregate.Actor.do_dispatch/4`** — existing command dispatch path (lines 156-223). Two-stage finalization inserts between the `aggregate.handle_command/2` call and the `send CommandRouter, {:append, …}` call (the new path runs the validation, the I/O, the re-decide, and then uses the existing `send/receive` protocol + `commit_event/3` to persist the enriched event spec). The Actor NEVER calls `EventStore.append_to_stream/3` directly.
- **`ForemanServer.Aggregate.Actor` bounded-retry path** — existing `reload_after_conflict/1` (lines 248-267). The compensation path (AC-020-3) integrates with the existing `{:error, ^ref, :wrong_expected_version, _}` return-value handling from CommandRouter. The compensation calls `BeadsAdapter.complete/3` (subprocess I/O) and emits telemetry — it does NOT route through `CommandRouter` (it is not a domain event).
- **`ForemanServer.Application` `maybe_*_child/0` pattern** — opt-in supervisor child pattern (existing; mirrored for the watcher and janitor).
- **`ForemanServer.Events.TaskCreated`** — existing event struct with `@enforce_keys [:task_id, :project_id, :title, :status, :task_type]`; `external_id` is an existing optional field. No `EventCodec` re-registration is required.
- **`ForemanServer.TaskProvider.Registry`** — existing per-project routing; extended with (a) `:create` transition support in `route/2` (no signature change) and (b) a new public helper `project_config/1` (added in TRD-005-TASK) that returns `{:ok, %{provider_module: module(), config: map()}} | {:error, atom()}`. `BeadsAdapter.create/2` calls `Registry.project_config(project_id)` as its first line to resolve the `database_path` it needs for the `--db` argv flag — `route/2` returns only the module and is therefore insufficient for `create/2`. The 3-case match in `handle_call({:project_config, project_id}, ...)` mirrors the existing `route_provider/3` for `{project_id, database_path}` and returns `:task_provider_not_configured` / `:provider_unavailable_for_project` for the same failure modes (without the `database_path_mismatch` cross-check, which is a `route/2` concern).

#### 2.2.6 Architecture Decisions (Numbered)

The architecture is committed to the following decisions. Each is named and justified; deviations require a TRD revision.
1. **Single-event linkage design.** The bead-linkage signal rides on `TaskCreated.external_id` (an existing optional field). No new typed event (`TaskBeadLinked` was considered and rejected in PRD 1.0.2). Justification: the slice invariant ("every emitted event is owned by an aggregate's `handle_command/2`; no module fabricates events") is preserved end-to-end; the two-stage finalization lets the Actor sequence I/O without manufacturing a second event. The projection map and the read-side `GET /api/tasks/:id` already expose the linkage through `external_id`.
2. **Two-stage aggregate finalization contract.** The Actor's `do_dispatch/4` runs four stages: validate (pure), I/O (only if validation passed + project supports `:create` + `cmd.payload.external_id` is `nil`), re-decide (pure, with `external_id` enriched), and finally the existing Actor↔CommandRouter append/ack protocol (`send CommandRouter, {:append, …}` + `receive {:append_ok, …}` + `commit_event/3`). The aggregate stays pure throughout (no I/O at any stage); the Actor NEVER mutates `event_spec` after `handle_command/2` returns and NEVER calls `EventStore.append_to_stream/3` directly (architecture test enforces CommandRouter as the sole append point). The Actor enriches the COMMAND payload, not the event spec.


3. **In-flight bead cache (process-local).** `state.in_flight_beads: %{command_id => bead_handle}` lives on the Actor's state. The cache prevents two `br create` invocations for the same logical command (initial dispatch + `reload_after_conflict` retry). The cache is cleared only on terminal success or terminal compensation; transient retries NEVER clear the cache. The cache is process-local and does NOT survive a crash; the orphan janitor absorbs crash-stranded beads on its grace-window scan.

4. **CommandGateway boundary invariant.** `dispatch_operator/2` MUST reject `task.create` envelopes with non-nil `payload.external_id` at the existing envelope allowlist guard. `dispatch_system/2` is unchanged and remains the trusted path for the watcher-import branch. The invariant is enforced ONCE at the boundary; the Actor does not duplicate the origin check. Adding a new dispatch path (or a new operator type) requires re-validating the boundary invariant.

5. **Pre-emptive Foreman-side validation.** `BeadsAdapter.create/2` rejects out-of-range priority (must be 0..P4) and out-of-enum `task_type` BEFORE constructing argv. This prevents the CodeMap's `INVALID_PRIORITY` / `INVALID_ISSUE_TYPE` rows from firing on inputs the system could have rejected earlier; the CodeMap rows remain reachable only when `br`'s own validation finds something Foreman's check missed (e.g. a future schema change).

6. **Watcher single-cursor invariant (3-way cursor priority).** `read_offset` is the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED — (a) the start byte of the first transient complete-line if the loop stopped at a transient; (b) the start byte of any trailing fragment if the file ends on an unterminated JSONL line; (c) the file size (EOF) if the file ends on a terminator. `partial_line` is the bytes of the FIRST LINE NOT TERMINALLY DISPATCHED — transient-line bytes from the split, trailing fragment bytes from `last_segment`, or `""` respectively (observability only, NOT required for correctness on the next poll). Terminal advance moves `read_offset` past `byte_size(line) + 1`; transient holds `read_offset` at the transient-line start and stops the loop. A write that straddles a poll boundary is never dropped or double-counted; a transient dispatch never skips queued lines.

7. **Watcher terminal-vs-transient dispatch classification (EXHAUSTIVE).** The watcher's terminal set is the aggregate's `task.create` domain rejection set wrapped by the gateway: `{:ok, _}`; `{:error, {:already_exists, :task, _}}`; `{:error, {:invalid_task_status, _}}`; `{:error, {:project_archived, _}}`; `{:error, :project_id_required}`. Every other return is transient (retryable). The classifier pattern-matches the FULL gateway return shape (outer wrapper preserved, inner reason matched by arity); the watcher's terminal set is the EXHAUSTIVE list of `CommandGateway.dispatch_system/2` returns that are NOT transient. `ProviderError` is NEVER produced by the watcher-import branch because the watcher dispatches via `dispatch_system/2` and bypasses `BeadsAdapter.create/2`.

8. **Watcher restart contract (full-replay-on-every-boot).** The watcher does NOT maintain a durable offset. On every boot, the watcher reads the JSONL from offset 0 to current EOF, applies the parse + dedupe + suppress + dispatch pipeline, then captures the boot-completion cursor and enters tail mode via `:file.open/2` + `Process.send_after(self(), :read_more, @poll_ms)` polling. The `ProjectionStore` dedupe check is the cross-restart safety net — operator beads that arrived during downtime are recovered on the next boot's replay.

9. **Opt-in supervisor children.** `:start_beads_watcher?` and `:start_beads_orphan_janitor?` both default to `false` in `config/test.exs` and `config/runtime.exs`. The `maybe_beads_watcher_child/0` and `maybe_beads_orphan_janitor_child/0` helpers mirror the existing `maybe_json_schema_cache_child/0` / `maybe_project_provider_projector_child/0` pattern. Operators opt into both flags for production but the flags exist for staged rollouts.

10. **Orphan janitor close-only-our-orphans.** The janitor closes ONLY foreman-tagged beads (`Map.has_key?(parsed["agent_context"] || %{}, "foreman")`). Untagged beads are NEVER touched. The check is at the top of the scan loop, before any `br close` call. The check is the architectural invariant that prevents the janitor from closing operator-managed beads.

11. **Backwards-compatible projection extension.** The `external_id` field addition to the `TaskCreated` projection map is additive. Existing `TaskCreated` events in the event store do not carry `external_id`; the projection handler reads `event_spec.payload.external_id` (default `nil` via `Map.get(payload, :external_id)` semantics) and writes the field. Foreman's read API returns `external_id: nil` for legacy tasks; for new tasks, it returns the bead ID. The change is additive; no codec re-registration is required.
12. **Canonical attrs contract (7-key map, FOREMAN-SIDE).** `BeadsAdapter.create/2` accepts a single `attrs` map whose keys are FIXED at the boundary: `%{task_id :: String.t(), command_id :: String.t(), title :: String.t(), description :: String.t() | nil, priority :: non_neg_integer(), task_type :: String.t(), dedupe_key :: String.t() | nil}`. The two correlation handles `task_id` and `command_id` live INSIDE `attrs` (PRD AC-020-1 and AC-021-3 trace both to this map; PRD 2-arity `create(project_id, attrs)` signature is preserved). Missing any required key at the call site is a pre-emptive validation failure (per Decision #5) routed to the appropriate CodeMap row before argv construction. `source_repo` is a derived field on `%TaskProvider.Issue{}` (Section 2.2.1 Component Boundaries BEAD_CREATED row), NOT a key on `attrs`. `dedupe_key` is preserved on attrs for future-extension `--dedupe-key` argv flag (TRD-003 Action #5). **`description` is `String.t() | nil` on attrs** — nil is the operator-omitted-description case; the runner-payload (Decision #14) normalizes nil → `""`. **No `:agent_context` key on attrs** — the agent_context JSON is CONSTRUCTED in the attrs → runner-payload transform (Decision #14) from `attrs.task_id` + `attrs.command_id` + the static `origin: "foreman"` + an ISO8601 UTC `linked_at` timestamp captured at the call site. **The attrs shape is the FOREMAN-SIDE boundary contract** — the runner-payload map consumed by `SystemBrunner` (Decision #14) is a SUBSIDIARY shape constructed at the `BeadsAdapter.create/2` boundary via a one-key rename (`:task_type` → `:type`), a nil normalization (`:description` nil → `""`), and a constructed string field (`:agent_context` from the four foreman tag fields).
13. **`TaskProvider.Registry.project_config/1` helper.** `BeadsAdapter.create/2` resolves the per-project `database_path` via `Registry.project_config(project_id)` as its first line. The helper's return shape is `{:ok, %{provider_module: module(), config: map()}} | {:error, atom()}` where `config` carries `:database_path`. The 3-case match in `handle_call({:project_config, project_id}, …)` mirrors the existing `route_provider/3` for `{project_id, database_path}` and returns `:task_provider_not_configured` / `:provider_unavailable_for_project` for the same failure modes (without the `database_path_mismatch` cross-check, which is a `route/2` concern). `BeadsAdapter.create/2` propagates a `Registry.project_config/1` failure as terminal `CREATE_FAILED` (AC-020-5; no `br create` argv construction). `route/2` signature is UNCHANGED (no backwards-incompatible change); `project_config/1` is a new public helper (TRD-005-TASK).
14. **`BrRunner.cmd/3` sole public API; `SystemBrunner` owns argv construction; runner-payload is the SUBSIDIARY shape (DERIVED from canonical attrs).** The `BrRunner` behaviour is `cmd(request, project_config, opts)` (defined at `br_runner.ex:28-30`). `SystemBrunner` owns ALL argv construction — it is the only place the `br create` argv shape can change. **Runner-payload shape (SUBSIDIARY to the canonical attrs map from Decision #12):** `%{title :: String.t(), type :: String.t(), priority :: non_neg_integer(), description :: String.t(), agent_context :: String.t()}`. Note `type` (matching `br create --type`), NOT `task_type` (which is the Foreman-side canonical key — renamed in the transform). `description` is `String.t()` (NOT nullable) — nil on attrs is normalized to `""` at the transform boundary. `agent_context` is `String.t()` — the JSON is CONSTRUCTED at the transform boundary (NOT a key on attrs). **Attrs → runner-payload transform (TRD-003 Action #5; runs after pre-emptive validation, before `BrRunner.cmd/3`):** (1) `attrs.task_type` → `payload.type` (the ONLY key rename); (2) `attrs.description` → `payload.description` with nil → `""` normalization (the ONLY nullable field); (3) Construct `payload.agent_context` = `Jason.encode!(%{foreman: %{task_id: attrs.task_id, command_id: attrs.command_id, origin: "foreman", linked_at: <iso8601-utc-now>}})` built from canonical attrs correlation handles + the static `origin: "foreman"` + an ISO8601 UTC timestamp captured at the call site (the JSON is never accepted from the call site — `BeadsAdapter` owns its construction); (4) `attrs.title` → `payload.title` (passthrough); (5) `attrs.priority` → `payload.priority` (passthrough); (6) `attrs.task_id`, `attrs.command_id`, `attrs.dedupe_key` are preserved on the canonical attrs map for correlation and future-extension `--dedupe-key` argv flag, but do NOT enter the runner-payload (they live in the adapter boundary only). The transform is centralized at TRD-003 to make every key decision explicit and testable. A dedicated `build_action_argv(:create, payload)` clause MUST call `validate_payload_shape!(:create, payload)` FIRST (line 1 of the body), mirroring the existing `:set_priority` pattern at `system_br_runner.ex:176-185`. The default `tap`-deferred validator at line 198-204 only works for `:flags`-extracted actions and would crash with `KeyError` / `Protocol.UndefinedError` on direct `payload.field` access if a dedicated clause tried to defer validation. Action-specific argv order: `["--title", payload.title, "--type", payload.type, "--priority", Integer.to_string(payload.priority), "--description", payload.description, "--agent-context", payload.agent_context] |> maybe_append_json_flag()`. The `--json` flag is appended by the existing `maybe_append_json_flag/1` helper at line 307. Payload keys read by `SystemBrunner`: `[:title, :type, :priority, :description, :agent_context]`. `project_config` shape passed to `BrRunner.cmd/3`: `%{database_path: db_path}`. Extension is TRD-016-TASK.

---

## Master Task List

The work is shipped as **3 PRs** with **31 master entries** (15 implementation tasks + 15 paired test tasks + 1 docs-only task). Each PR has a `**Shippable State:**` line that names the integration point that PR makes runnable. Tasks are formatted in the parser-compatible checklist shape:

`- [ ] **TRD-NNN-TASK**: <description> [satisfies REQ-NNN] [depends: TRD-NNN, TRD-NNN]`

followed by a `Validates PRD ACs: AC-NNN-M, AC-NNN-M` body line, optional `Target File:` / `Actions:` lines, and optional sub-checklists.

### PR 1 — `TaskProvider` behaviour extension + `BeadsAdapter.create/2`

**Shippable State:** `BeadsAdapter.create/2` is runnable end-to-end with mocked `BrRunner`; the `TaskProvider` behaviour advertises the new callback (12 entries); `BeadsAdapter.capabilities/0` advertises `:create`. An Actor invocation that exercises the path will get the bead ID from the mocked subprocess without yet wiring the synchronous hook (the synchronous hook lands in PR 2). The 5 new CodeMap rows are in place; pre-emptive Foreman-side validation rejects out-of-range inputs before constructing argv. The Actor still produces a `TaskCreated` event with `external_id: nil` at the end of PR 1.

- [ ] **TRD-001-TASK**: Extend `ForemanServer.TaskProvider` behaviour with `@callback create/2` declaration (between `name/0` and `capabilities/0`); add a `@doc` line for `create/2` describing the `TaskProvider.Issue` return shape and the `command_id` correlation handle. [satisfies REQ-025]
  Validates PRD ACs: AC-025-3
  Target File: `packages/foreman_server/lib/foreman_server/task_provider.ex`
  Actions:
  1. Add `@callback create(project_id :: String.t(), attrs :: map()) :: {:ok, %TaskProvider.Issue{}} | {:error, %ProviderError{}}` after the existing callbacks. The canonical `attrs` map carries seven keys (see Architecture Decision #12): `task_id :: String.t()` (correlation handle from `cmd.payload.task_id`), `command_id :: String.t()` (correlation handle from the dispatching `cmd.command_id` — the same correlation handle referenced in PRD AC-020-1 and AC-021-3), `title :: String.t()`, `description :: String.t() | nil`, `priority :: non_neg_integer()` (must be 0..P4), `task_type :: String.t()` (closed enum), `dedupe_key :: String.t() | nil`. All seven keys are required at the boundary; `task_id` and `command_id` are the two correlation handles that flow into the `--agent-context` JSON (AC-021-1), and the five data fields drive the `br create` argv. Missing any required key at the call site is a pre-emptive validation failure (`INVALID_TITLE` / `INVALID_PRIORITY` / `INVALID_ISSUE_TYPE` CodeMap rows per TRD-004-TASK).
  2. Update the behaviour `@moduledoc` callback list to include `create/2` and document the canonical attrs shape from Action #1.
  3. Verify `behaviour_info(:callbacks)` returns 12 entries with `{:create, 2}` as the new tuple.

- [ ] **TRD-001-TEST**: Update `task_provider_test.exs` behaviour-shape test: `length(callbacks) == 12` at lines 12 AND 24; add `assert {:create, 2} in callbacks` after the existing `add_dependency` assertion. [verifies TRD-001] [satisfies REQ-025]
  Validates PRD ACs: AC-025-3
  Target File: `packages/foreman_server/test/foreman_server/task_provider_test.exs`

- [ ] **TRD-002-TASK**: Extend `BeadsAdapter.capabilities/0` to include `:create` in the `supports` list (now `[:claim, :close, :reopen, :annotate, :set_priority, :set_assignee, :list_dependencies, :add_dependency, :remove_dependency, :create]`); update the `@doc` to describe the new capability. [satisfies REQ-025] [depends: TRD-001-TASK]
  Validates PRD ACs: AC-025-2
  Target File: `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter.ex`

- [ ] **TRD-002-TEST**: Add a capabilities assertion in `beads_adapter_test.exs`: `assert :create in BeadsAdapter.capabilities().supports`; verify the 10-entry support list. [verifies TRD-002] [satisfies REQ-025]
  Validates PRD ACs: AC-025-2
  Target File: `packages/foreman_server/test/foreman_server/task_providers/beads_adapter_test.exs`

- [ ] **TRD-003-TASK**: Implement `ForemanServer.TaskProviders.BeadsAdapter.create/2` — build the `:create` request payload (with `--agent-context` JSON containing the four tag fields `foreman.task_id`, `foreman.command_id`, `foreman.origin = "foreman"`, `foreman.linked_at` ISO8601 UTC), call `BrRunner.cmd/3` with the request tuple, parse the JSON output, wrap into `TaskProvider.Issue{id, title, description, status, priority, issue_type, source_repo, ...}`. Pre-emptive Foreman-side validation rejects out-of-range priority (must be 0..P4) and out-of-enum `task_type` before constructing the payload (routes to `INVALID_PRIORITY` / `INVALID_ISSUE_TYPE` CodeMap rows). [satisfies REQ-020] [satisfies REQ-021] [satisfies REQ-026] [depends: TRD-001-TASK] [depends: TRD-002-TASK] [depends: TRD-004-TASK]
  Validates PRD ACs: AC-020-1, AC-021-1, AC-021-3, AC-026-2, AC-026-3
  Target File: `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter.ex`
  Actions:
1. Add the `create/2` public function. Signature: `def create(project_id, attrs)` per PRD AC-020 — `project_id` is the Foreman-side opaque string; `attrs` is the canonical seven-key map (see Architecture Decision #12): `%{task_id, command_id, title, description, priority, task_type, dedupe_key}`. The two correlation handles (`task_id`, `command_id`) flow into the `--agent-context` JSON (Action #4); the five data fields (`title`, `description`, `priority`, `task_type`, `dedupe_key`) drive the `br create` argv flags (Action #5). The `source_repo` field on the returned `TaskProvider.Issue` is a derived field populated from the `br create` JSON envelope (line 13 of the bead record), NOT an input on `attrs`.
2. **Resolve `database_path` via `TaskProvider.Registry.project_config/1`.** The first line of `create/2` calls `TaskProvider.Registry.project_config(project_id)` and matches `{:ok, %{config: %{database_path: db_path}}}`. On `{:error, reason}` return `{:error, %ProviderError{code: :CREATE_FAILED, retryable?: false, message: "registry config unresolved", context: %{project_id: project_id, reason: reason}}}` — this is a terminal config error, NOT transient. The existing `Registry.project_config/1` helper is added in TRD-005-TASK; the helper returns `{:ok, %{provider_module: ..., config: ...}}` so future providers can resolve their own per-project config without exposing the registry internals.
3. **Pre-emptive Foreman-side validation (before constructing the request payload).** In order: (a) reject missing or empty `title` with `INVALID_TITLE`; (b) reject `priority` outside 0..P4 with `INVALID_PRIORITY`; (c) reject `task_type` not in the closed enum with `INVALID_ISSUE_TYPE`; (d) reject missing `task_id` or missing `command_id` (the two correlation handles required by the `--agent-context` JSON per AC-021-3) with `INVALID_TITLE` CodeMap row (treat empty correlation handles as a title-equivalent validation failure since the bead record cannot be linked back to a Foreman task without them). All four checks happen BEFORE `BeadsAdapter.scrub_argv/1` and BEFORE the `BrRunner.cmd/3` call.
4. Use `BeadsAdapter.scrub_argv/1` per `PRD-2026-48f7b420` REQ-019 to escape the four tag fields.
5. **Build the action-specific request payload (the `br` boundary is `BrRunner.cmd/3` per `br_runner.ex:28-30`, NOT `run/1`).** Construct the payload map and call `BrRunner.cmd({:create, payload}, project_config, opts)`:
   - The `agent_context` JSON is `#{Jason.encode!(%{foreman: %{task_id: attrs.task_id, command_id: attrs.command_id, origin: "foreman", linked_at: DateTime.utc_now() |> DateTime.to_iso8601()}})}` — atom keys per `CommandGateway`'s payload-key convention; both correlation IDs are sourced from the `attrs` map (Action #1), NOT regenerated; the `origin` literal is `"foreman"`; `linked_at` is `DateTime.utc_now() |> DateTime.to_iso8601()`.
   - The request payload is `%{title: attrs.title, type: attrs.task_type, priority: attrs.priority, description: attrs.description, agent_context: agent_context_json}` — these are the action-specific keys `SystemBrRunner.build_action_argv(:create, payload)` reads (see TRD-016-TASK).
   - `project_config = %{database_path: db_path}` is the `:config` map resolved in Action #2 (`Registry.project_config/1` returns `{:ok, %{provider_module: ..., config: cfg}}`; BeadsAdapter extracts `cfg` and passes it directly to the runner — matching the existing `BrRunner.cmd/3` call pattern used by `list_ready/2`, `coordination_status/2`, etc. in `beads_adapter.ex:72, 110, 143`).
   - `opts = [timeout_ms: 30_000]` per the existing `BR_TIMEOUT_SUBPROCESS` mapping (`PRD-2026-48f7b420` REQ-009-2).
   - The `dedupe_key` is held on the `attrs` map for future use (Beads adapter passes it as a future-extension `--dedupe-key` argv flag in a follow-up PRD — this slice does not wire it; it is preserved on `attrs` only).
   - **`BrRunner.run/1` does not exist** — the only public API on `ForemanServer.TaskProviders.BrRunner` is `cmd/3` (`br_runner.ex:28-30`). All argv construction is owned by `ForemanServer.TaskProviders.SystemBrRunner`; the `:create` action is added in TRD-016-TASK.
6. Parse the JSON envelope and return `{:ok, %TaskProvider.Issue{id: bead_id, ...}}` on success; route failure modes through `CodeMap` for `{:error, %ProviderError{}}`. On `BrRunner.cmd/3` failure modes, `CodeMap` translates `{:error, %ProviderError{code: ..., retryable?: ..., message: ..., context: ...}}` per TRD-004-TASK rows.

- [ ] **TRD-003-TEST**: Comprehensive `BeadsAdapter.create/2` test suite covering the canonical seven-key attrs shape (see Architecture Decision #12). The boundary under test is `BrRunner.cmd/3` (the only public API on `ForemanServer.TaskProviders.BrRunner` per `br_runner.ex:28-30`); `BrRunner.run/1` does NOT exist and is NEVER asserted against. Argv construction is delegated to `SystemBrRunner` and is covered by TRD-016-TEST, not here. (1) **happy path** — call `BeadsAdapter.create("proj-x", %{task_id: "tsk-1", command_id: "cmd-1", title: "Add login", description: "OAuth flow", priority: 2, task_type: "feature", dedupe_key: "dk-1"})` with mocked `TaskProvider.Registry.project_config/1` returning `{:ok, %{provider_module: BeadsAdapter, config: %{database_path: "/abs/beads.db"}}}` and `BrRunnerMock` stubbed to return `{:ok, %{stdout: ~s({"id":"foreman-abc","title":"Add login","priority":2,"issue_type":"feature"})}}` — assert Mox captured the `cmd({:create, payload}, %{database_path: "/abs/beads.db"}, _opts)` call with `payload.title == "Add login"`, `payload.type == "feature"`, `payload.priority == 2`, `payload.description == "OAuth flow"`, and `payload.agent_context` is a JSON string (not a parsed map); (2) **`--agent-context` JSON shape assertion** — parse `payload.agent_context` (the JSON string passed in the request payload) and assert the decoded JSON has `foreman.task_id == "tsk-1"`, `foreman.command_id == "cmd-1"`, `foreman.origin == "foreman"`, and `foreman.linked_at` parses as ISO8601 UTC; (3) **request payload shape (not argv)** — assert Mox captured exactly one `cmd/3` call with `payload` containing keys `[:title, :type, :priority, :description, :agent_context]` and `project_config` equal to `%{database_path: "/abs/beads.db"}` (the `Registry.project_config/1` `:config` map); argv-level assertions live in TRD-016-TEST where `SystemBrRunner` is the unit under test; (4) **pre-emptive validation** — (a) `attrs.title = ""` routes to `INVALID_TITLE` CodeMap row (non-retryable); (b) `attrs.priority = 5` routes to `INVALID_PRIORITY` (non-retryable); (c) `attrs.task_type = "bogus"` routes to `INVALID_ISSUE_TYPE` (non-retryable); (d) `attrs.task_id = nil` (or `attrs.command_id = nil`) routes to `INVALID_TITLE` (treat missing correlation handles as title-equivalent validation failure per TRD-003-TASK Action #3); (5) **registry config resolution failure (`:task_provider_not_configured`)** — `Registry.project_config/1` returns `{:error, :task_provider_not_configured}`; assert `create/2` returns `{:error, %ProviderError{code: :CREATE_FAILED, retryable?: false, context: %{project_id: "proj-x", reason: :task_provider_not_configured}}}` and NO `BrRunner.cmd/3` invocation occurs (Mox expectation fails if called); (6) **registry config resolution failure (`:provider_unavailable_for_project`)** — `Registry.project_config/1` returns `{:error, :provider_unavailable_for_project}`; assert `create/2` returns the same `CREATE_FAILED` envelope with `reason: :provider_unavailable_for_project` (terminal, non-retryable); (7) **attrs contract regression** — call `create/2` with `attrs = %{title: "x"}` (missing five keys); assert a clear pre-emptive validation error and NO `BrRunner.cmd/3` invocation. [verifies TRD-003] [satisfies REQ-020] [satisfies REQ-021] [satisfies REQ-026] [depends: TRD-016-TASK]
  Validates PRD ACs: AC-020-1, AC-021-1, AC-021-3, AC-026-2, AC-026-3
  Target File: `packages/foreman_server/test/foreman_server/task_providers/beads_adapter_create_test.exs`

- [ ] **TRD-004-TASK**: Add 5 new CodeMap rows to `BeadsAdapter.CodeMap`: `INVALID_TITLE` (non-retryable, `retryable?: false`), `INVALID_PRIORITY` (non-retryable, `retryable?: false`), `INVALID_ISSUE_TYPE` (non-retryable, `retryable?: false`), `DUPLICATE_TASK_ID` (non-retryable, `retryable?: false`), `CREATE_FAILED` (fallback, `retryable?: true` — propagated from `br.retryable` per `PRD-2026-48f7b420` REQ-008-2 unknown-code policy). Each row sets `code`, `retryable?`, `message` template, `hint` template, and reuses the existing 8-key `context` allowlist (no new keys). [satisfies REQ-026]
  Validates PRD ACs: AC-026-1, AC-026-2, AC-026-3, AC-026-4, AC-026-5
  Target File: `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter_code_map.ex`

- [ ] **TRD-004-TEST**: CodeMap routing tests for all 5 rows: (1) `{error: {code: "VALIDATION", hint: "title required"}}` → `INVALID_TITLE` (non-retryable); (2) `{error: {code: "VALIDATION", hint: "priority must be 0-4"}}` → `INVALID_PRIORITY` (non-retryable); (3) `{error: {code: "VALIDATION", hint: "issue_type must be one of ..."}}` → `INVALID_ISSUE_TYPE` (non-retryable); (4) `{error: {code: "DUPLICATE", hint: "id collision"}}` → `DUPLICATE_TASK_ID` (non-retryable); (5) signal / timeout / generic envelope / unexpected exit code → `CREATE_FAILED` (retryable, `retryable?` propagated from `br.retryable`). [verifies TRD-004] [satisfies REQ-026]
  Validates PRD ACs: AC-026-1, AC-026-2, AC-026-3, AC-026-4, AC-026-5
  Target File: `packages/foreman_server/test/foreman_server/task_providers/beads_adapter_code_map_test.exs`

- [ ] **TRD-005-TASK**: (a) Extend `TaskProvider.Registry` with a NEW public helper `project_config/1 :: (project_id :: String.t()) :: {:ok, %{provider_module: module(), config: map()}} | {:error, atom()}` that resolves the per-project registration state (currently held internally in `state.per_project[project_id]`) and returns BOTH the provider module AND the per-project config map (containing `:database_path`). This is what `BeadsAdapter.create/2` calls to look up the `database_path` it needs for the `--db` argv flag (the existing `route/2` returns `{:ok, provider_module}` only and is therefore insufficient for `create/2`). (b) Wire the helper into the `handle_call({:project_config, project_id}, ...)` callback with the exact 3-case match on `state.per_project[project_id]`: `{:ok, {:active, %{provider_module: pm, config: config}}}` → `{:ok, %{provider_module: pm, config: config}}`; `{:ok, {:unavailable, reason}}` → `{:error, :provider_unavailable_for_project}`; `:error` → `{:error, :task_provider_not_configured}`. (c) Update `route/2` (line 69) to keep dispatching `:create` to the same per-project state (no signature change — `route/2` still returns `{:ok, module()}` for capability gating; `project_config/1` is the resolution path). (d) `register_for_project/3` (line 89) is unchanged (the `:create` action reuses the same per-project state as the other 8 operational callbacks). [satisfies REQ-020] [satisfies REQ-025] [depends: TRD-001-TASK] [depends: TRD-003-TASK]
  Validates PRD ACs: AC-020-4
  Target File: `packages/foreman_server/lib/foreman_server/task_providers/registry.ex`

- [ ] **TRD-005-TEST**: Registry `:create` routing + `project_config/1` resolution tests: (1) register a project with `BeadsAdapter` as the `task_provider` and `%{database_path: "/abs/beads.db"}` as the config; invoke `TaskProvider.Registry.route(:create, %{project_id: id})` and assert the returned provider is `BeadsAdapter`; (2) invoke `TaskProvider.Registry.project_config(project_id)` and assert it returns `{:ok, %{provider_module: BeadsAdapter, config: %{database_path: "/abs/beads.db"}}}`; (3) gate semantics for `route/2`: a project with NO `task_provider` registered returns `{:error, :no_provider}`; a project with a provider that does NOT advertise `:create` returns `{:error, :capability_not_supported}`; (4) gate semantics for `project_config/1`: an unregistered project_id returns `{:error, :task_provider_not_configured}`; a project marked `{:unavailable, :br_binary_missing}` returns `{:error, :provider_unavailable_for_project}`; a project registered with `BeadsAdapter` but with `config = %{}` (no `:database_path`) returns `{:ok, %{provider_module: BeadsAdapter, config: %{}}}` (the registry does NOT validate the config shape — `BeadsAdapter.create/2` raises on missing `database_path` per the existing pattern in `list_ready/2`). [verifies TRD-005] [satisfies REQ-020] [satisfies REQ-025]
  Validates PRD ACs: AC-020-4
  Target File: `packages/foreman_server/test/foreman_server/task_providers/registry_test.exs`
- [ ] **TRD-016-TASK**: Extend `ForemanServer.TaskProviders.SystemBrRunner` with a new `:create` action. The `BrRunner` behaviour is `cmd(request, project_config, opts)` (`br_runner.ex:28-30`); `SystemBrRunner` owns ALL argv construction and is the only place the `br create` argv shape can change. Concrete changes in `packages/foreman_server/lib/foreman_server/task_providers/system_br_runner.ex`: (1) **Extend `@action_subcommands` (line 10)** with `create: "create"` so `Map.fetch!(@action_subcommands, :create)` returns the `"create"` subcommand (matches the existing `:ready`, `:show`, etc. pattern). (2) **Add `build_argv({:create, _payload} = request, project_config)` clause** that returns `["br", "create", "--db", database_path | action_argv]` where `database_path = fetch_database_path!(project_config)` and `action_argv = build_action_argv(:create, payload)` (mirrors the existing `build_argv({:coordination_status, _}, project_config)` clause at line 115-119). (3) **Add `build_action_argv(:create, payload)` clause** as a DEDICATED clause that mirrors the `:set_priority` pattern at line 176-185 — NOT the default `extract_flags!`-based clause. Order matters: **call `validate_payload_shape!(:create, payload)` FIRST** (line 1 of the body), THEN build the action-specific argv in documented order: `["--title", payload.title, "--type", payload.type, "--priority", Integer.to_string(payload.priority), "--description", payload.description, "--agent-context", payload.agent_context] |> maybe_append_json_flag()`. The `--json` flag is appended by the existing `maybe_append_json_flag/1` helper at line 307. **Why dedicated-with-validate-first and not the generic default clause:** the default `build_action_argv(action, payload)` at line 198-204 calls `validate_payload_shape!(action, payload)` via `tap(...)` AFTER argv construction — that ordering only works because the default clause uses `extract_flags!` and never indexes `payload.field` directly. A dedicated `:create` clause that builds `["--title", payload.title, ...]` will crash with `KeyError` (missing key) or `Protocol.UndefinedError` (`Integer.to_string(nil)`) BEFORE the `tap`-wrapped validator runs, which would produce confusing errors instead of the explicit `ArgumentError` the validator emits. The dedicated clauses `:set_priority` (line 176-185) and `:add_dependency` (line 187-196) both follow the validate-first ordering — `:create` must too. (4) **Add `validate_payload_shape!(:create, payload)` clause** that raises `ArgumentError` if any of `:title` (non-empty binary), `:type` (non-empty binary), `:priority` (integer in 0..4), `:description` (binary, may be empty for `nil`-equivalent — `BeadsAdapter.create/2` always passes a string, even for empty descriptions), `:agent_context` (non-empty binary) is malformed — mirrors the existing `:set_priority` shape validator at line 214-230. The validator runs as line 1 of the dedicated `:create` clause (NOT deferred to a `tap`); it is the primary shape contract and the only line that catches a missing `:title` BEFORE `payload.title` is dereferenced. This validator is a defensive net against `BeadsAdapter.create/2` bugs, not a primary input-validation layer (TRD-003 Action #3 owns primary validation at the BeadsAdapter boundary). [satisfies REQ-020] [satisfies REQ-021] [satisfies REQ-026]
  Validates PRD ACs: AC-020-1, AC-021-1, AC-021-3
  Target File: `packages/foreman_server/lib/foreman_server/task_providers/system_br_runner.ex`

- [ ] **TRD-016-TEST**: `system_br_runner_create_test.exs` — covers the `:create` action argv construction and payload shape validation. This is where the argv-array assertions live (NOT in TRD-003-TEST, where only the `BrRunner.cmd/3` request payload is asserted): (1) **happy-path argv construction** — call `SystemBrRunner.cmd({:create, %{title: "Add login", type: "feature", priority: 2, description: "OAuth flow", agent_context: ~s({"foreman":{"task_id":"tsk-1","command_id":"cmd-1","origin":"foreman","linked_at":"2026-08-11T06:39:00Z"}})}}, %{database_path: "/abs/beads.db"}, [])` and assert the resulting argv (intercepted at the `:erlang.open_port/2` boundary or via a Port-mock helper) is exactly `["br", "create", "--db", "/abs/beads.db", "--title", "Add login", "--type", "feature", "--priority", "2", "--description", "OAuth flow", "--agent-context", <agent_context_json>, "--json"]` in documented order; (2) **`--agent-context` argv passes through verbatim** — the value of `payload.agent_context` is the exact JSON string emitted to argv (NOT re-encoded); (3) **`--json` appended by default** — same call without an explicit `flags: ["--json"]` in the payload still produces `--json` at the end (matches the `:set_priority` argv fixture); (4) **payload shape validation — `:title` missing** — `SystemBrunner.cmd({:create, %{type: "feature", priority: 2, description: "x", agent_context: "{}"}}, project_config, [])` raises `ArgumentError` with a message referencing `:title`; (5) **payload shape validation — `:priority` out of range** — `priority: 5` raises `ArgumentError` referencing `:priority` and `0..4`; (6) **payload shape validation — `:type` missing** — `:type` absent raises `ArgumentError`; (7) **unknown action rejected by `validate_request!`** — `:bogus` action raises `ArgumentError` with `"unknown br action: :bogus"` (confirms the new `:create` entry is correctly registered in `@action_subcommands`); (8) **missing `:database_path` in `project_config`** — `cmd({:create, %{title: "x", type: "feature", priority: 2, description: "y", agent_context: "{}"}}, %{}, [])` raises `ArgumentError` referencing `:database_path` (defensive — TRD-003-TEST already covers the higher-level `Registry.project_config/1` failure mode that prevents this). [verifies TRD-016] [satisfies REQ-020] [satisfies REQ-021] [satisfies REQ-026]
  Validates PRD ACs: AC-020-1, AC-021-1, AC-021-3
  Target File: `packages/foreman_server/test/foreman_server/task_providers/system_br_runner_create_test.exs`

**PR 1 shippable:** `BeadsAdapter.create/2` is runnable from REPL with a mocked `BrRunner`. The synchronous hook is not yet wired; the Actor still produces a `TaskCreated` event with `external_id: nil`. Pre-emptive Foreman-side validation rejects out-of-range inputs before constructing argv. All 5 new CodeMap rows are in place; the 8-key `context` allowlist is unchanged.

### PR 2 — Actor two-stage finalization + in-flight cache + boundary invariant

**Shippable State:** The synchronous two-stage finalization hook is wired into `do_dispatch/4` end-to-end. Issuing `foreman task create` for a Beads-backed project produces a `TaskCreated` event with `external_id` populated via the second `handle_command/2` invocation. The Actor's `in_flight_beads` cache prevents two `br create` calls for the same `command_id`. The `CommandGateway` boundary invariant (`dispatch_operator/2` rejects `task.create` with non-nil `external_id`) is enforced at the existing envelope allowlist guard. The watcher and janitor are not yet active (lands in PR 3).

- [ ] **TRD-006-TASK**: Extend `ForemanServer.Aggregate.Actor` state with `in_flight_beads: %{command_id => bead_handle}` field (default `%{}` in `init/1`); the field is part of the state struct (or map), not a GenServer-managed state. Update `reload_after_conflict/1` and `do_dispatch/4` to carry the field through rehydration. The cache is process-local and does NOT survive a crash (AC-024-3). [satisfies REQ-024]
  Validates PRD ACs: AC-024-1, AC-024-2, AC-024-3, AC-024-4
  Target File: `packages/foreman_server/lib/foreman_server/aggregate/actor.ex`
  Actions:
  1. Add `in_flight_beads: %{}` to the initial state in `init/1`.
  2. Carry the field through the recursion (no special handling — it lives on the state, like `version`).
  3. Document the CLOSE-ONLY-ONCE guarantee in a code comment: the cache is consulted before any `BeadsAdapter.complete/3` call; once cleared, no subsequent close is issued for the same logical command.

- [ ] **TRD-006-TEST**: Actor state init test: `init/1` returns state with `in_flight_beads: %{}`; a state round-trip through `reload_after_conflict/1` preserves the field when present. State-after-step assertion: invoke `do_dispatch/4` once; verify the field is populated on the success path; verify the field is cleared after the append confirmation. [verifies TRD-006] [satisfies REQ-024]
  Validates PRD ACs: AC-024-1, AC-024-2, AC-024-3, AC-024-4
  Target File: `packages/foreman_server/test/foreman_server/aggregate/actor_in_flight_cache_test.exs`

- [ ] **TRD-007-TASK**: Insert two-stage finalization hook in `do_dispatch/4` (between `aggregate.handle_command/2` returning `{:ok, event_spec}` and the existing Actor↔CommandRouter append/ack protocol). Stage 1: call `aggregate.handle_command/2` with the original command. Per-project gate: if `cmd.payload.external_id` is `nil` AND `BeadsAdapter.capabilities().supports` has `:create` AND `state.in_flight_beads[cmd.command_id]` is absent, proceed to stage 2; if `cmd.payload.external_id` is non-nil, watcher-import branch — proceed to stage 4 with the stage-1 event_spec (no `br create`); if `:create` not in `supports`, proceed to stage 4 with `event_spec.payload.external_id == nil` (no `br create`). Stage 2: in-flight cache lookup (if `Map.get(state.in_flight_beads, cmd.command_id)` hits, REUSE cached bead ID and jump to stage 3); otherwise call `BeadsAdapter.create/2` and store the returned `bead_id` in `state.in_flight_beads[cmd.command_id]`. On `{:error, %ProviderError{}}` (any of `INVALID_TITLE` / `INVALID_PRIORITY` / `INVALID_ISSUE_TYPE` / `DUPLICATE_TASK_ID` / `CREATE_FAILED`) return the error from `do_dispatch/4` (AC-020-5 — NO `TaskCreated` event, telemetry `[:create, :failure]`, NO cache population for this `command_id`). Stage 3: re-run `aggregate.handle_command/2` with `%{original_cmd | payload: Map.put(original_cmd.payload, :external_id, bead_id)}` — the aggregate deterministically returns `{:ok, %{event_type: "TaskCreated", payload: %{...external_id: bead_id...}}}`. The Actor NEVER mutates `event_spec` after `handle_command/2` returns. Stage 4: hand off the (stage-1 or stage-3) event_spec to the existing Actor↔CommandRouter append/ack protocol — `event_data = normalize_to_event_data(event_spec)`; `ref = make_ref()`; `send CommandRouter, {:append, aggregate_id, [event_data], expected_version, ref, self()}`; on `receive {:append_ok, ^ref, count, append_latency_ms}` call `commit_event/3` (which calls `state.aggregate_module.apply_event(state.module_state, event_spec)` and bumps `state.version`); clear `state.in_flight_beads[cmd.command_id]` on terminal success. The Actor NEVER calls `EventStore.append_to_stream/3` directly. [satisfies REQ-020] [depends: TRD-003-TASK] [depends: TRD-005-TASK] [depends: TRD-006-TASK]
  Validates PRD ACs: AC-020-1, AC-020-4, AC-020-5, AC-020-6
  Target File: `packages/foreman_server/lib/foreman_server/aggregate/actor.ex`
  Actions:
  1. Refactor `do_dispatch/4` to call `handle_command/2` first (stage 1); the existing `event_spec` becomes the stage-1 event spec.
  2. Add the per-project gate after stage 1; branch into stage 2, watcher-import branch, or direct stage 4.
  3. Implement stage 2 with in-flight cache lookup; on `BeadsAdapter.create/2` error return the error from `do_dispatch/4` (no `normalize_to_event_data`, no append).
  4. Implement stage 3 with command-payload enrichment; verify the aggregate emits the enriched event.
  5. Implement stage 4 with `normalize_to_event_data` + the existing Actor↔CommandRouter append/ack protocol (`send CommandRouter, {:append, aggregate_id, [event_data], expected_version, ref, self()}` → `receive {:append_ok, ^ref, count, append_latency_ms}` → `commit_event/3` which calls `aggregate.apply_event/2` and bumps `state.version`); clear the cache on terminal success. The Actor NEVER calls `EventStore.append_to_stream/3` directly (architecture test enforces this).
  6. Emit `[:foreman_server, :task_provider, :beads, :create, :skipped_watcher_import]` for the watcher-import branch with `command_id`, `bead_id`, `task_id`, `project_id`.

- [ ] **TRD-007-TEST**: Comprehensive `actor_hook_test.exs`: (1) AC-020-1 happy path — mock `BrRunner` returns bead ID; assert `send CommandRouter, {:append, aggregate_id, [event_data], expected_version, ref, self()}` was invoked; on `receive {:append_ok, ^ref, count, latency_ms}` verify `commit_event/3` was called and the normalized event data has `external_id == bead_id`; (2) AC-020-4 non-Beads project — capabilities without `:create`; verify the hook is a no-op (no `BeadsAdapter.create/2`, no `send CommandRouter, {:append, …}` for the bead); verify `external_id` remains `nil` in the persisted event; (3) AC-020-5 failure path — `BeadsAdapter.create/2` returns `{:error, %ProviderError{code: "INVALID_TITLE"}}`; verify the Actor returns the error from `do_dispatch/4` WITHOUT invoking `normalize_to_event_data` or sending `{:append, …}` to CommandRouter; verify `[:create, :failure]` telemetry; verify NO `TaskCreated` event in the event store; (4) AC-020-6 watcher-import branch — synthesize `task.create` via `dispatch_system/2` with `external_id: bead.id`; verify `BeadsAdapter.create/2` is NOT invoked; verify the bead ID is preserved on the persisted `TaskCreated` event; (5) AC-024-1 in-flight cache hit — replay the same `command_id`; verify the second call uses the cached bead ID and does NOT re-invoke `BeadsAdapter.create/2`; (6) AC-024-2 cache clear on terminal success — assert cache cleared after `receive {:append_ok, ^ref, count, …}`; (7) AC-024-4 concurrent `command_id`s — two concurrent `task.create` commands for DIFFERENT `command_id`s; each carries its own cache entry; no collision. [verifies TRD-007] [satisfies REQ-020] [satisfies REQ-024]
  Validates PRD ACs: AC-020-1, AC-020-4, AC-020-5, AC-020-6, AC-024-1, AC-024-2, AC-024-4
  Target File: `packages/foreman_server/test/foreman_server/aggregate/actor_hook_test.exs`

- [ ] **TRD-008-TASK**: Append-conflict compensation path. On `receive {:error, ^ref, :wrong_expected_version, _}` from CommandRouter (after `BeadsAdapter.create/2` has populated the cache) with bounded retries remaining: the recursive `do_dispatch` reloads state via `reload_after_conflict/1` (which preserves `state.in_flight_beads` via `%{state | module_state: …, version: …}`), re-runs `aggregate.handle_command/2` with the cached `bead_id` already present in the payload (the AC-020-3 stage-3 path, NOT a fresh `BeadsAdapter.create/2` call), and re-sends the enriched event spec to CommandRouter with the new `expected_version`. NO `BeadsAdapter.complete/3` and NO cache clear happens on a transient retry attempt. Compensation (`BeadsAdapter.complete(project_id, bead_id, %{transition_comment: "foreman-compensation:append-conflict-retry-exhausted"})` OR `"foreman-compensation:re-decision-rejected"` respectively) + cache clear + error surfaced to caller triggers ONLY on (a) bounded-retry exhaustion (`@max_conflict_retries` reached) or (b) post-reload re-decision rejection (`{:error, _}` from `handle_command/2`). Compensation is subprocess I/O against the Beads CLI; it does NOT route through CommandRouter (not a domain event). On compensation failure emit `[:foreman_server, :task_provider, :beads, :create, :compensate_failure]` and the orphan janitor (REQ-023) takes over on its next grace-window scan. Emit `[:foreman_server, :task_provider, :beads, :create, :compensated]` on successful compensation. CLOSE-ONLY-ONCE: `in_flight_beads[command_id]` consulted before any close; once cleared, no subsequent close for the same logical command. [satisfies REQ-020] [satisfies REQ-024] [depends: TRD-007-TASK]
  Validates PRD ACs: AC-020-3
  Target File: `packages/foreman_server/lib/foreman_server/aggregate/actor.ex`

- [ ] **TRD-008-TEST**: Compensation path test: (1) append-conflict on first attempt — CommandRouter stub sends back `{:error, ^ref, :wrong_expected_version, latency_ms}` once, then `{:append_ok, ^ref, count, latency_ms}`; verify the Actor consults the cache, reloads state via `reload_after_conflict/1`, re-runs `handle_command/2` with the cached `external_id`, re-sends the enriched event spec to CommandRouter; verify NO `BeadsAdapter.create/2` call on retry; verify `in_flight_beads` is preserved across the reload (NOT cleared); verify the eventual `TaskCreated` event has `external_id: bead_id`; (2) bounded-retry exhaustion — CommandRouter stub returns `:wrong_expected_version` `@max_conflict_retries + 1` times; verify `BeadsAdapter.complete/3` is called with `transition_comment: "foreman-compensation:append-conflict-retry-exhausted"`; verify the cache is cleared; verify `[:create, :compensated]` telemetry is emitted; verify the error is returned from `do_dispatch/4`; verify NO further `send CommandRouter, {:append, …}` after exhaustion; (3) post-reload re-decision rejection — CommandRouter stub returns `:wrong_expected_version` once, but the reloaded state makes the original command invalid (e.g. `{:error, :phase_terminal}`); verify compensation closes the bead with `transition_comment: "foreman-compensation:re-decision-rejected"`; (4) compensation failure — mock `BeadsAdapter.complete/3` returns error; verify `[:create, :compensate_failure]` telemetry is emitted; the cache is cleared. [verifies TRD-008] [satisfies REQ-020] [satisfies REQ-024]
  Validates PRD ACs: AC-020-3
  Target File: `packages/foreman_server/test/foreman_server/aggregate/actor_compensation_test.exs`

- [ ] **TRD-009-TASK**: CommandGateway boundary invariant. Extend `ForemanServer.CommandGateway.dispatch_operator/2` (existing envelope allowlist guard at `command_gateway.ex`) to reject `task.create` envelopes with non-nil `payload.external_id` — return `{:error, :external_id_not_allowed_via_operator}`. The check is `get_in(envelope, [:payload, :external_id]) != nil` (atom keys per `CommandGateway`'s payload-key convention). `dispatch_system/2` is unchanged and remains the trusted path for the watcher-import branch. The Actor does NOT duplicate this check (avoiding redundant enforcement). [satisfies REQ-020] [depends: TRD-007-TASK]
  Validates PRD ACs: AC-020-7
  Target File: `packages/foreman_server/lib/foreman_server/command_gateway.ex`

- [ ] **TRD-009-TEST**: CommandGateway boundary invariant test: (1) `dispatch_operator/2` with `task.create` and `payload.external_id: nil` is accepted (reaches `CommandRouter`); (2) `dispatch_operator/2` with `task.create` and `payload.external_id: "foreman-abc"` returns `{:error, :external_id_not_allowed_via_operator}` BEFORE reaching the Actor; (3) `dispatch_system/2` with `task.create` and `payload.external_id: "foreman-abc"` is accepted (trusted path). The test asserts the rejection happens at the CommandGateway allowlist, NOT in the Actor. [verifies TRD-009] [satisfies REQ-020]
  Validates PRD ACs: AC-020-7
  Target File: `packages/foreman_server/test/foreman_server/command_gateway_external_id_guard_test.exs`

**PR 2 shippable:** `foreman task create --project-id <beads-backed> --title "..."` produces a `TaskCreated` event with `external_id` populated via the synchronous two-stage hook. The Actor's `in_flight_beads` cache prevents two `br create` calls for the same `command_id`. The `CommandGateway` boundary invariant (`dispatch_operator/2` rejects `task.create` with non-nil `external_id`) is enforced at the existing envelope allowlist guard. The watcher and orphan janitor are not yet booted (they are opt-in via `:start_beads_watcher?` / `:start_beads_orphan_janitor?` flags; PR 3 activates them).

### PR 3 — JSONL watcher + orphan janitor + opt-in supervision + docs

**Shippable State:** The bi-directional sync is live. The watcher forwards Beads-side operator-managed beads to Foreman as `task.create` commands via `CommandGateway.dispatch_system/2`; the orphan janitor closes the Foreman-side strands. The `ProjectionStore` `TaskCreated` handler stores `external_id` (legacy events default to `nil`). The flags `:start_beads_watcher?` / `:start_beads_orphan_janitor?` default to `false` in `config/test.exs` and are documented in `config/runtime.exs`. With both flags `true`, the supervisor boots `BeadsWatcher` and `BeadsOrphanJanitor` per registered project.

- [ ] **TRD-010-TASK**: Extend `ForemanServer.ProjectionStore.apply_event_by_type(state, "TaskCreated", payload)` (lines 775-791) to include `external_id: payload["external_id"]` (or `event_spec.payload.external_id`) in the task map. The new field is inserted after `task_id` and is always present in the task map (default `nil` for legacy events that did not carry `external_id`). Idempotency is provided by the aggregate's stream-version semantics, not by a separate handler. [satisfies REQ-025] [depends: TRD-007-TASK]
  Validates PRD ACs: AC-025-1
  Target File: `packages/foreman_server/lib/foreman_server/projection_store.ex`

- [ ] **TRD-010-TEST**: `projection_store_task_external_id_test.exs`: (1) `TaskCreated` event with `external_id: "foreman-abc"` → task map includes `external_id: "foreman-abc"`; (2) `TaskCreated` event WITHOUT `external_id` (legacy) → task map includes `external_id: nil`; (3) `ProjectionStore.get_task(external_id: bead_id)` (keyword arity, `/1`) returns the task map including `external_id`; (4) the read-side `GET /api/tasks/:id` returns the bead ID in the response body when `external_id` is populated. [verifies TRD-010] [satisfies REQ-025]
  Validates PRD ACs: AC-025-1
  Target File: `packages/foreman_server/test/foreman_server/projection_store_task_external_id_test.exs`

- [ ] **TRD-011-TASK**: Implement `ForemanServer.TaskProviders.BeadsWatcher` — supervised GenServer; one process per registered project. State shape: `%{project_id, jsonl_path, file_handle, read_offset, partial_line, poll_ms}`. On `init/1`: resolve JSONL path via `BrRunner.cmd({:where, %{database_path: db_path}}, %{database_path: db_path}, timeout_ms: 30_000)` (the `BrRunner` behaviour is `cmd/3` per `br_runner.ex:28-30`; `:where` is already supported by `SystemBrRunner` per `@action_subcommands` at line 10 of `system_br_runner.ex` and matches the existing pattern at `beads_adapter.ex:1424`), open file with `:file.open/2` `[:read, :binary, :raw]`, run `BeadsWatcher.boot_replay/1` (reads offset 0 → EOF, applies parse + dedupe + dispatch pipeline; emits `[:watcher, :replay_started]` and `[:watcher, :replay_completed]` with `lines_processed`, `lines_imported`, `lines_suppressed`, `lines_reconciled`). On boot completion, set `read_offset` to the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED (3-way cursor priority — `(a)` the start byte of the first transient complete-line if the loop stopped at a transient; `(b)` the start byte of any trailing fragment if the file ends on an unterminated JSONL line; `(c)` the file size (EOF) if the file ends on a terminator). `partial_line` is the bytes of the FIRST LINE NOT TERMINALLY DISPATCHED — transient-line bytes from the split, trailing fragment bytes from `last_segment`, or `""` respectively (observability only, NOT required for correctness on the next poll). Tail mode (`handle_info(:read_more, state)`) reads from `read_offset` to EOF, splits on newlines, processes each complete line, and reschedules itself with `Process.send_after(self(), :read_more, state.poll_ms)`. [satisfies REQ-022] [satisfies REQ-024] [depends: TRD-016-TASK]
  Validates PRD ACs: AC-022-1
  Target File: `packages/foreman_server/lib/foreman_server/task_providers/beads_watcher.ex`
  Actions:
  1. Define the module with `use GenServer`; state struct (or map) with the six fields above.
  2. Implement `init/1` that resolves the JSONL path, opens the file, calls `boot_replay/1`, and schedules the first `:read_more`.
  3. Implement `boot_replay/1` that reads offset 0 → EOF, applies the parse + dedupe + suppress + dispatch pipeline (delegated to `read_more/1` for the loop body), and emits the boot telemetry.
  4. Implement `handle_info(:read_more, state)` that reads from `read_offset` to EOF, splits on newlines, processes each complete line, and schedules the next `:read_more`.
  5. Implement the 3-way cursor priority for boot and tail mode (per Architecture Decision §2.2.6 item 6).

- [ ] **TRD-011-TEST**: `beads_watcher_test.exs` boot replay and tail mode tests: (1) boot replay reads offset 0 → EOF and applies the parse + dedupe + dispatch pipeline; (2) foreman-tagged bead → `[:watcher, :skipped]`; (3) already-imported bead (dedupe hit on `ProjectionStore.get_task(external_id: bead.id)`) → `[:watcher, :reconciled]`; (4) new operator bead → `[:watcher, :imported]` (asserts `dispatch_system/2` was called with the deterministic envelope); (5) `[:watcher, :replay_started]` and `[:watcher, :replay_completed]` emitted with the four counters; (6) tail mode captures the boot-completion cursor; (7) subsequent `:read_more` reads from `read_offset` to EOF (does NOT prepend `partial_line`); (8) transient dispatch failure does NOT advance `read_offset` and retries with the same deterministic `command_id`; (9) **single-cursor invariant (3-way cursor priority)** — `read_offset` HOLDS at the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED (first transient complete-line, trailing fragment start, or EOF); `partial_line` is the bytes of that first undispatched line; terminal advance moves `read_offset` past `byte_size(line) + 1`; (10) **boot transient retention test** — fixture contains a transient complete-line followed by N queued complete-lines; the watcher boots, dispatches the first bead, the dispatch returns transient; `read_offset` HOLDS at the transient-line start (NOT advanced); subsequent polls re-read the transient complete-line and re-attempt with the same deterministic `command_id`; (11) **boot fragment retention test** — fixture ends on an unterminated JSONL fragment; the watcher reads the fragment, sets `read_offset` to the fragment start byte, sets `partial_line` to the fragment bytes; subsequent poll completes the fragment and processes the resulting line. [verifies TRD-011] [satisfies REQ-022]
  Validates PRD ACs: AC-022-1
  Target File: `packages/foreman_server/test/foreman_server/task_providers/beads_watcher_test.exs`

- [ ] **TRD-012-TASK**: In `BeadsWatcher.read_more/1` (tail mode), implement the per-line pipeline: parse JSON; check `agent_context.foreman` (suppress + emit `[:foreman_server, :task_provider, :beads, :watcher, :skipped]` per AC-022-3); check `ProjectionStore` for `external_id == bead.id` (no-op + emit `[:watcher, :reconciled]` per AC-022-2); otherwise synthesize a `task.create` command envelope with `command_id = "beads-cmd:" <> project_id <> ":" <> bead_id`, `aggregate_id = "task:" <> task_id` (where `task_id = "beads:" <> project_id <> ":" <> bead_id`), and payload `{external_id: bead_id, title, description, priority, task_type: issue_type, project_id}`. Dispatch via `CommandGateway.dispatch_system/2` (the trusted system path; emit `[:watcher, :imported]`). Implement the 3-way cursor priority + Option A single-cursor invariant for the line loop: `read_offset` HOLDS at the transient-line start and stops the loop on transient; terminal advance moves `read_offset` past `byte_size(line) + 1`. The terminal set is exhaustive: `{:ok, _}`; `{:error, {:already_exists, :task, _}}`; `{:error, {:invalid_task_status, _}}`; `{:error, {:project_archived, _}}`; `{:error, :project_id_required}`. Every other return is transient. [satisfies REQ-022] [depends: TRD-011-TASK]
  Validates PRD ACs: AC-022-2, AC-022-3
  Target File: `packages/foreman_server/lib/foreman_server/task_providers/beads_watcher.ex`

- [ ] **TRD-012-TEST**: Watcher pipeline tests: (1) foreman-tagged bead is suppressed; `[:watcher, :skipped]` telemetry carries the bead ID; (2) already-imported bead (ProjectionStore hit) is a no-op; `[:watcher, :reconciled]` telemetry; (3) new operator-originated bead triggers `dispatch_system/2` with the deterministic envelope (`command_id`, `aggregate_id`, `task_id`, `external_id`); `[:watcher, :imported]` telemetry; (4) `dispatch_system/2` is REJECTED via `dispatch_operator/2` if the test mistakenly routes there (boundary invariant verification); (5) transient dispatch (`ProviderError{retryable?: true}` synthetic; `{:error, {:wrong_expected_version, 5, 6}}`; `{:exit, :killed}`) does NOT advance `read_offset` and retries with the same `command_id`; (6) terminal dispatch (`{:ok, _}`; `{:error, {:already_exists, :task, _}}`; `{:error, {:invalid_task_status, _}}`; `{:error, {:project_archived, _}}`; `{:error, :project_id_required}`) advances `read_offset`. [verifies TRD-012] [satisfies REQ-022]
  Validates PRD ACs: AC-022-2, AC-022-3
  Target File: `packages/foreman_server/test/foreman_server/task_providers/beads_watcher_pipeline_test.exs`

- [ ] **TRD-013-TASK**: Implement `ForemanServer.TaskProviders.BeadsOrphanJanitor` — supervised GenServer; one process per registered project. State shape: `%{project_id, jsonl_path, grace_ms, scan_interval_ms}`. On `init/1`: resolve JSONL path; the first scan happens after `@grace_ms` (default 300s) to avoid racing the synchronous hook on first boot; subsequent scans on `@scan_interval_ms` (default 60s). The scan loop: read the JSONL; filter for `agent_context.foreman` (untagged beads are NEVER touched); for each match, check `ProjectionStore` for the corresponding task's existence and status; for case (a) no task → close via `BeadsAdapter.complete/3` with `transition_comment: "foreman-orphan:no-task"`; for case (b) task closed/failed → close with `transition_comment: "foreman-orphan:terminal-task"`; for non-foreman-tagged beads → skip with `[:foreman_server, :task_provider, :beads, :orphan, :janitor, :retained]`. On close, emit `[:foreman_server, :task_provider, :beads, :orphan, :janitor, :closed]` carrying `bead_id`, `project_id`, and the elapsed milliseconds since `linked_at`. [satisfies REQ-023]
  Validates PRD ACs: AC-023-1, AC-023-2, AC-023-3, AC-023-4
  Target File: `packages/foreman_server/lib/foreman_server/task_providers/beads_orphan_janitor.ex`

- [ ] **TRD-013-TEST**: `beads_orphan_janitor_test.exs`: (1) grace-window semantics — no scan before `@grace_ms`; (2) case (a) — foreman-tagged bead with NO corresponding Foreman task → close with `transition_comment: "foreman-orphan:no-task"`; `[:orphan, :janitor, :closed]` telemetry with `bead_id`, `project_id`, elapsed ms; (3) case (b) — foreman-tagged bead with corresponding Foreman task in `closed` / `failed` state → close with `transition_comment: "foreman-orphan:terminal-task"`; (4) non-foreman-tagged bead → skip; `[:orphan, :janitor, :retained]` telemetry; (5) `BeadsAdapter.complete/3` is NOT called for non-foreman-tagged beads (the architectural invariant). [verifies TRD-013] [satisfies REQ-023]
  Validates PRD ACs: AC-023-1, AC-023-2, AC-023-3, AC-023-4
  Target File: `packages/foreman_server/test/foreman_server/task_providers/beads_orphan_janitor_test.exs`

- [ ] **TRD-014-TASK**: Add `maybe_beads_watcher_child/0` and `maybe_beads_orphan_janitor_child/0` to `ForemanServer.Application`. Both follow the existing `maybe_json_schema_cache_child/0` / `maybe_project_provider_projector_child/0` pattern. Opt-in via `:start_beads_watcher?` / `:start_beads_orphan_janitor?` config flags (default `false`). Update `config/test.exs` to set both flags to `false` (per the existing `start_json_schema_cache?` precedent). Update `config/runtime.exs` to document the flags. [satisfies REQ-022] [satisfies REQ-023] [depends: TRD-012-TASK] [depends: TRD-013-TASK]
  Validates PRD ACs: AC-022-4, AC-023-1
  Target File: `packages/foreman_server/lib/foreman_server/application.ex`, `packages/foreman_server/config/test.exs`, `packages/foreman_server/config/runtime.exs`

- [ ] **TRD-014-TEST**: Application supervisor child opt-in tests: (1) with `:start_beads_watcher?` `false`, `BeadsWatcher` is NOT in the supervision tree; (2) with `:start_beads_watcher?` `true`, `BeadsWatcher` IS in the supervision tree; (3) with `:start_beads_orphan_janitor?` `false`, `BeadsOrphanJanitor` is NOT in the supervision tree; (4) with `:start_beads_orphan_janitor?` `true`, `BeadsOrphanJanitor` IS in the supervision tree. Tests run with the flags set per the default `config/test.exs` to avoid booting the watcher/janitor in unit-test mode. [verifies TRD-014] [satisfies REQ-022] [satisfies REQ-023]
  Validates PRD ACs: AC-022-4, AC-023-1
  Target File: `packages/foreman_server/test/foreman_server/application_supervisor_test.exs`

- [ ] **TRD-015-TASK**: Update documentation per the `foreman-doc-gate` skill: (1) `docs/user-guide.md` — per-project `task_provider` registration extension (`:create` capability), watcher / janitor opt-in semantics, `foreman doctor task_provider` orphan backlog lines, `foreman task create` output shape (bead ID printed when present); (2) `docs/cli-reference.md` — `foreman task create` output shape, `foreman doctor task_provider` adds watcher / janitor / orphan backlog lines, `--json` output now includes `external_id` when the project is Beads-backed; (3) `README.md` — high-level overview of the synchronous create + bi-directional sync with compensating consistency, boundary reminder on the Actor hook insertion point (`aggregate/actor.ex` lines 156-223 are the synchronous hook insertion point, NOT the aggregate handlers); (4) `CLAUDE.md` — slice invariant reminder ("every emitted event is owned by an aggregate's `handle_command/2`; no module fabricates events") and the two opt-in flags. [depends: TRD-014-TASK]
  Validates PRD ACs: (docs — no PRD ACs; per `foreman-doc-gate` skill)
  Target File: `docs/user-guide.md`, `docs/cli-reference.md`, `README.md`, `CLAUDE.md`

**PR 3 shippable:** The bi-directional sync is live. With `:start_beads_watcher?` and `:start_beads_orphan_janitor?` set to `true` in `config/runtime.exs`, the supervisor boots `BeadsWatcher` and `BeadsOrphanJanitor` per registered project. A `foreman task create` for a Beads-backed project materialises a bead synchronously with the synchronous in-process all-or-nothing guarantee (and compensating recovery for the residual cases); an operator-managed bead whose title matches a Foreman project's intent is auto-imported by the watcher; orphaned foreman-tagged beads are recovered by the janitor within the grace window.

---

## Acceptance Criteria Traceability

| REQ-NNN | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-020 | Two-stage aggregate finalization: synchronous `task.create` bead creation in the Actor hook (compensating consistency, not true atomicity) | TRD-003-TASK, TRD-005-TASK, TRD-007-TASK, TRD-008-TASK, TRD-009-TASK | TRD-003-TEST, TRD-005-TEST, TRD-007-TEST, TRD-008-TEST, TRD-009-TEST |
| REQ-021 | Foreman-originated beads carry an `agent_context` tag | TRD-003-TASK | TRD-003-TEST |
| REQ-022 | JSONL watcher for bi-directional sync | TRD-011-TASK, TRD-012-TASK, TRD-014-TASK | TRD-011-TEST, TRD-012-TEST, TRD-014-TEST |
| REQ-023 | Orphan janitor closes Foreman's stranded beads | TRD-013-TASK, TRD-014-TASK | TRD-013-TEST, TRD-014-TEST |
| REQ-024 | Actor hook guard via `command_id`-keyed in-flight bead cache | TRD-006-TASK, TRD-007-TASK, TRD-008-TASK | TRD-006-TEST, TRD-007-TEST, TRD-008-TEST |
| REQ-025 | Projection map stores `external_id`; BeadsAdapter advertises `:create` | TRD-001-TASK, TRD-002-TASK, TRD-010-TASK | TRD-001-TEST, TRD-002-TEST, TRD-010-TEST |
| REQ-026 | `br create` failure modes mapped in `BeadsAdapter.CodeMap` | TRD-003-TASK, TRD-004-TASK | TRD-003-TEST, TRD-004-TEST |

**Coverage:** 7 REQs / 30 ACs / 15 implementation tasks + 15 paired test tasks + 1 docs-only task = 31 master entries. Every PRD REQ-NNN has ≥ 1 implementation task and ≥ 1 test task.

### Per-AC traceability (verbatim cross-reference to PRD §4)

| AC ID | Description (abbreviated) | Master Task |
|---|---|---|
| AC-020-1 | Happy path: stage 1 validate → stage 2 `BeadsAdapter.create/2` → stage 3 re-decide with `external_id` → stage 4 append; aggregate emits `TaskCreated{external_id: bead_id}` | TRD-003-TASK, TRD-007-TASK |
| AC-020-2 | `TaskCreated.external_id` round-trips through projection to `GET /api/tasks/:id` | TRD-010-TASK |
| AC-020-3 | Append-conflict compensation: CommandRouter returns `{:error, ref, :wrong_expected_version, _}` → Actor cache hit → reload_after_conflict/1 (preserves `in_flight_beads`) → re-decide + re-send to CommandRouter; bounded-retry exhaustion OR post-reload re-decision rejection → `BeadsAdapter.complete/3` (subprocess I/O, NOT a CommandRouter event) + cache clear + clear error from `do_dispatch/4`; CLOSE-ONLY-ONCE | TRD-007-TASK, TRD-008-TASK |
| AC-020-4 | Non-Beads project: stage 2 is a no-op; `external_id` remains `nil` | TRD-005-TASK, TRD-007-TASK |
| AC-020-5 | Failure-as-error: `br create` error returns from `do_dispatch/4` without `normalize_to_event_data` / `send CommandRouter, {:append, …}`; telemetry `[:create, :failure]` | TRD-007-TASK |
| AC-020-6 | Watcher-import branch: pre-populated `external_id` skips `BeadsAdapter.create/2`; telemetry `[:create, :skipped_watcher_import]` | TRD-007-TASK |
| AC-020-7 | `CommandGateway.dispatch_operator/2` rejects non-nil `external_id`; `dispatch_system/2` is unchanged | TRD-009-TASK |
| AC-021-1 | `--agent-context` JSON carries four Foreman tag fields | TRD-003-TASK |
| AC-021-2 | Foreman-tagged beads recognised by watcher and janitor; untagged beads NEVER touched | TRD-012-TASK, TRD-013-TASK |
| AC-021-3 | Tag shape: `task_id`, `command_id`, `origin = "foreman"`, `linked_at` ISO8601 UTC | TRD-003-TASK |
| AC-022-1 | Watcher boot replay + tail mode with single-cursor invariant (3-way cursor priority + Option A) | TRD-011-TASK, TRD-012-TASK |
| AC-022-2 | Watcher dedupe via `ProjectionStore` (no-op for already-imported); synthetic envelope routing via `dispatch_system/2` with deterministic `command_id` | TRD-012-TASK |
| AC-022-3 | Watcher suppresses foreman-tagged beads | TRD-012-TASK |
| AC-022-4 | `:start_beads_watcher?` opt-in: `false` → no watcher; `true` → one tail per registered project | TRD-014-TASK |
| AC-023-1 | Janitor first scan after grace window (default 300s); subsequent scans on interval (default 60s) | TRD-013-TASK, TRD-014-TASK |
| AC-023-2 | Case (a) — foreman-tagged with no task → close with `"foreman-orphan:no-task"` | TRD-013-TASK |
| AC-023-3 | Case (b) — foreman-tagged with task in `closed` / `failed` → close with `"foreman-orphan:terminal-task"` | TRD-013-TASK |
| AC-023-4 | Non-foreman-tagged beads NEVER touched | TRD-013-TASK |
| AC-024-1 | In-flight cache consulted before any `br create`; cache hit reuses cached bead ID | TRD-006-TASK, TRD-007-TASK |
| AC-024-2 | Cache cleared on terminal success OR terminal compensation; NEVER cleared on transient | TRD-006-TASK, TRD-008-TASK |
| AC-024-3 | Cache is process-local; does NOT survive a crash; orphan janitor absorbs strander | TRD-006-TASK |
| AC-024-4 | Concurrent `command_id`s each carry their own cache entry; no collision | TRD-006-TASK |
| AC-025-1 | `ProjectionStore.TaskCreated` handler stores `external_id` (default `nil` for legacy) | TRD-010-TASK |
| AC-025-2 | `BeadsAdapter.capabilities/0` advertises `:create` in `supports` | TRD-002-TASK |
| AC-025-3 | `TaskProvider` behaviour callback count 12 with `{:create, 2}` tuple | TRD-001-TASK |
| AC-026-1 | `INVALID_TITLE` CodeMap row (non-retryable) | TRD-003-TASK, TRD-004-TASK |
| AC-026-2 | `INVALID_PRIORITY` CodeMap row (non-retryable); pre-emptive Foreman-side validation | TRD-003-TASK, TRD-004-TASK |
| AC-026-3 | `INVALID_ISSUE_TYPE` CodeMap row (non-retryable); pre-emptive Foreman-side validation | TRD-003-TASK, TRD-004-TASK |
| AC-026-4 | `DUPLICATE_TASK_ID` CodeMap row (non-retryable) | TRD-004-TASK |
| AC-026-5 | `CREATE_FAILED` fallback row (retryable; `retryable?` propagated from `br.retryable`) | TRD-004-TASK |

---

## Sprint Planning

The 3 PRs are time-boxed into 3 calendar sprints. This section is **informational only** — `implement-trd-beads` does not parse sprint headings; it parses the `### PR N:` headings in the Master Task List.

### Sprint 1 — `TaskProvider` behaviour extension + `BeadsAdapter.create/2`

Calendar: ~1 week. Tasks: TRD-001 through TRD-005 + TRD-016 (6 implementation + 6 paired test = 12 master entries). PR 1 is independently shippable: `BeadsAdapter.create/2` is runnable from REPL with a mocked `BrRunner`; the `SystemBrunner` dedicated `:create` clause in `build_action_argv/2` (validate-first ordering, mirroring `:set_priority`; TRD-016) is wired; the synchronous Actor hook is NOT yet wired. This lets the team land the adapter and its CodeMap in isolation, with the Actor hook as a follow-up PR.

### Sprint 2 — Actor two-stage finalization + in-flight cache + boundary invariant

Calendar: ~1 week. Tasks: TRD-006 through TRD-009 (4 implementation + 4 paired test = 8 master entries). PR 2 is the load-bearing slice — the two-stage finalization, in-flight cache, compensation path, and `CommandGateway` boundary invariant. All 30 PRD ACs in REQ-020, REQ-024 are exercised here. Tests: `actor_hook_test.exs` covers AC-020-1, AC-020-4, AC-020-5, AC-020-6, AC-024-1, AC-024-2, AC-024-4; `actor_compensation_test.exs` covers AC-020-3; `command_gateway_external_id_guard_test.exs` covers AC-020-7.

### Sprint 3 — JSONL watcher + orphan janitor + opt-in supervision + docs

Calendar: ~1 week. Tasks: TRD-010 through TRD-015 (5 implementation + 5 paired test + 1 docs-only = 11 master entries). PR 3 activates the bi-directional sync. Tests: `beads_watcher_test.exs` and `beads_watcher_pipeline_test.exs` cover AC-022-1, AC-022-2, AC-022-3; `beads_orphan_janitor_test.exs` covers AC-023-1, AC-023-2, AC-023-3, AC-023-4; `application_supervisor_test.exs` covers AC-022-4, AC-023-1. Docs (`TRD-015-TASK`) ship in the same PR per the `foreman-doc-gate` skill.

### After PR 3 merges

The bi-directional sync is live. `foreman task create --project-id <beads-backed>` materialises a bead synchronously with the in-process all-or-nothing guarantee (and compensating recovery for the residual cases); an operator-managed bead whose title matches a Foreman project's intent is auto-imported by the watcher; orphaned foreman-tagged beads are recovered by the janitor within the grace window. The next-on-deck work (out of scope here) is the `foreman bead audit` CLI surface, `task.update` flows, and a streaming watcher upgrade (`:file.inotify` / FSEvents).

---

## Reused Capabilities

The slice reuses the following existing infrastructure (no new code or contracts; integration only). Cross-references use the foundational TRD's micro UUID or the module path. Per the create-trd skill's Capability Reuse Check, the existing `TRD-2026-48f7b420-foreman-beads-task-provider` TRD is the foundation for this slice; the capability tokens it provides (BeadsAdapter, BeadsAdapter.CodeMap, BrRunner boundary, TaskProvider behaviour, JsonSchemaCache, ConcurrencyLimiter) are referenced by capability, not by label.

| Capability | Source | Where reused |
|---|---|---|
| `TaskProvider` behaviour (11 callbacks) | `TRD-2026-48f7b420` | TRD-001-TASK (extended with `create/2`) |
| `BeadsAdapter` adapter (8 operational callbacks) | `TRD-2026-48f7b420` | TRD-003-TASK (extended with `create/2`) |
| `BeadsAdapter.CodeMap` factory | `TRD-2026-48f7b420` | TRD-004-TASK (extended with 5 new rows) |
| `BrRunner` boundary (`SystemBrRunner` is the sole `System.cmd("br", ...)` site) | `TRD-2026-48f7b420` | TRD-003-TASK (argv construction; existing runner) |
| `BrRunnerMock` (test support) | `TRD-2026-48f7b420` | TRD-003-TEST, TRD-004-TEST (Mox stubs) |
| `TaskProvider.Registry` (per-project routing) | `TRD-2026-48f7b420` | TRD-005-TASK (extended to dispatch `:create`) |
| `ProviderError` typed struct with 8-key `context` allowlist | `TRD-2026-48f7b420` | TRD-004-TASK (5 new rows reuse the existing context shape) |
| `Aggregate.Actor.do_dispatch/4` command dispatch | `lib/foreman_server/aggregate/actor.ex` (existing) | TRD-007-TASK (two-stage finalization inserted) |
| `Aggregate.Actor.reload_after_conflict/1` bounded retry | `lib/foreman_server/aggregate/actor.ex` (existing) | TRD-008-TASK (compensation path integrates) |
| `ProjectionStore.apply_event_by_type/3` `TaskCreated` handler | `lib/foreman_server/projection_store.ex` (existing) | TRD-010-TASK (extended to include `external_id`) |
| `CommandGateway.dispatch_operator/2` envelope allowlist | `lib/foreman_server/command_gateway.ex` (existing) | TRD-009-TASK (extended to reject non-nil `external_id`) |
| `CommandGateway.dispatch_system/2` trusted path | `lib/foreman_server/command_gateway.ex` (existing) | TRD-007-TASK (watcher-import branch); TRD-012-TASK (watcher dispatch) |
| `Application.maybe_*_child/0` opt-in pattern | `lib/foreman_server/application.ex` (existing) | TRD-014-TASK (two new opt-in children) |
| `Events.TaskCreated` (existing optional `external_id` field) | `lib/foreman_server/events/task_created.ex` (existing) | TRD-007-TASK (single-event linkage); TRD-010-TASK (projection extension) |

No new typed events are introduced (no `EventCodec` re-registration required). No new operator types are added (no `CommandGateway.@allowed_operator_types` extension required). The single-event design preserves the slice invariant end-to-end.

---

## Architecture Self-Critique

The chosen architecture (Option C — two-stage aggregate finalization) was reviewed against the following gaps and risks. Each item is named with a recommended resolution.

### AC-1: Synchronous hook is a single point of latency

**Issue.** Every `task.create` now waits on `br create`. If `br` is misbehaving, every create hangs for the full timeout.

**Resolution.** The synchronous hook is bounded by the per-call timeout from `PRD-2026-48f7b420` REQ-009-2 (30s default). The compensation path (AC-020-3) handles append-conflict failures; the orphan janitor (REQ-023) handles cron-drop cases. The latency is on the create path only; read paths (`list_ready`, `get`) are unchanged. The latency is observable via `[:foreman_server, :task_provider, :beads, :create, :failure]` telemetry (carries `append_latency_ms`).

**Severity:** Low — bounded by an existing timeout; observable; recovery paths named.

### AC-2: Actor crash between `br create` success and the Actor↔CommandRouter `{:append_ok, …}` confirmation

**Issue.** If the Actor crashes after `BeadsAdapter.create/2` returns success but before receiving `{:append_ok, ^ref, count, append_latency_ms}` from CommandRouter, the bead is on disk in Beads but no Foreman task exists (CommandRouter's append is the event-log write that materialises the task projection).

**Resolution.** AC-024-3 makes the in-flight cache process-local so it does not survive the crash. The orphan janitor (REQ-023) picks up the bead on its grace-window scan (configurable, default 300s — covers normal `br create` latency + append latency + restart time). The append that succeeded before the crash is durable; the crash is a recovery problem, not a correctness one.

**Severity:** Low — recoverable within the grace window; the residual window is bounded.

### AC-3: Watcher-storm scenario (boot replay)

**Issue.** On every boot, the watcher reads the entire JSONL from offset 0 (full replay per AC-022-1). For a JSONL with N existing entries, replay is O(N) reads where each line takes one of three paths: foreman-tagged → skip (cheap), already-imported → no-op ProjectionStore check (cheap), operator-originated → dispatch.

**Resolution.** AC-022-2 dedupe makes the steady-state replay cost ~1 read + 1 short ProjectionStore lookup per line (no event-store appends for already-imported beads). The orphan janitor (REQ-023) absorbs any foreman-tagged residual the replay missed. Telemetry `[:watcher, :replay_started]` / `[:watcher, :replay_completed]` carries `lines_processed` / `lines_imported` / `lines_suppressed` / `lines_reconciled` so operators can size the storm. A future ops decision (out of scope here) is to add a JSONL compaction step or a streaming FSEvents watcher if N grows past operator tolerance.

**Severity:** Low — bounded by the existing JSONL size; observable; future-proofing documented.

### AC-4: Tag-spoofing risk

**Issue.** A Beads CLI operator could theoretically write `agent_context.foreman` themselves on a bead that Foreman did not create, fooling the watcher into suppressing it.

**Resolution.** The orphan janitor (REQ-023) is the safety valve — even a spoofed-tagged bead is closed only if no corresponding Foreman task exists with `external_id == bead.id` after the grace window. The Foreman-origination signal is "linked_at + command_id from THIS command" — the Actor captures `command_id` from the dispatching envelope and uses it both in the tag AND as the in-flight cache key (AC-024-1), so a spoofed tag without a matching `command_id` audit trail is detectable. The detection path is the `command_id` mismatch between the tag and the in-flight cache; the operational surface is the `[:foreman_server, :task_provider, :beads, :create, :command_id_mismatch]` telemetry (planned for a future slice).

**Severity:** Low — the orphan janitor is the safety valve; spoofing only delays the close, not the correctness.

### AC-5: Two supervisor flags default to `false`

**Issue.** A first-deploy environment that wants the watcher but not the janitor (or vice versa) gets mismatched behaviour.

**Resolution.** The four combinations are observable in `foreman doctor task_provider` output (each flag's state appears with a green check or red minus). Operators are expected to opt into both for production but the flags exist for staged rollouts. Documented in the docs-only task (`TRD-015-TASK`).

**Severity:** Informational — operator decision; no correctness impact.

---

## Task Coverage Analysis

| Coverage Dimension | Result |
|---|---|
| Every PRD REQ-NNN has ≥ 1 TRD task with `[satisfies REQ-NNN]` | YES — REQ-020, REQ-021, REQ-022, REQ-023, REQ-024, REQ-025, REQ-026 each have ≥ 1 implementation task and ≥ 1 test task |
| Every PRD AC-NNN-N has a paired master task | YES — see Per-AC traceability table above |
| Every user-facing implementation task has a paired `TRD-NNN-TEST` | YES — 15 implementation tasks with paired tests; 1 docs-only task (`TRD-015-TASK`) has no test (per `foreman-doc-gate` skill) |
| Every `### PR N:` section has a `**Shippable State:**` line | YES — PR 1, PR 2, PR 3 each have a `**Shippable State:**` line immediately after the heading |
| No PR `**Shippable State:**` is infrastructure-only | YES — PR 1: "BeadsAdapter.create/2 is runnable end-to-end with mocked BrRunner"; PR 2: "`foreman task create` for a Beads-backed project produces a `TaskCreated` event with `external_id` populated"; PR 3: "The bi-directional sync is live. The watcher forwards Beads-side operator-managed beads to Foreman; the orphan janitor closes the Foreman-side strands" |
| Forward dependencies (PR N task depends on PR N+1 task) | NONE — all dependencies flow backward (PR 1 → PR 2 → PR 3) |
| No circular dependencies | VERIFIED — the dependency graph is acyclic |
| Tasks estimated at ≥ 8h | NONE — all implementation tasks are S/M; no task ≥ 8h |
| `Total tasks` frontmatter matches actual count | 15 implementation + 15 paired test + 1 docs-only = 31 entries (frontmatter says 31) |

---

## Dependency and Estimate Review

### Dependency graph (acyclic)

```
TRD-001-TASK ──┬──> TRD-002-TASK ──┐
                │                    ├──> TRD-003-TASK ──┬──> TRD-004-TASK
                └──> TRD-005-TASK ──┘                    │
                                                          │
TRD-006-TASK ──> TRD-007-TASK ──> TRD-008-TASK           │
                                │                        │
                                └──> TRD-009-TASK        │
                                                          │
TRD-010-TASK <────────────────  TRD-007-TASK ─────────────┤
                                                          │
TRD-011-TASK ──> TRD-012-TASK ────────────────────────────┤
                                                          │
TRD-013-TASK ─────────────────────────────────────────────┤
                                                          │
TRD-014-TASK <── (TRD-012, TRD-013) ─────────────────────┤
                                                          │
TRD-015-TASK <── TRD-014-TASK
```

Critical path: TRD-001 → TRD-003 → TRD-007 → TRD-008 (estimated ~14h including test).

### Estimate confidence

| Range | Count | Notes |
|---|---|---|
| XS (< 1h) | 0 | — |
| S (1-2h) | 18 | Most implementation + test tasks; conservative |
| M (2-4h) | 12 | Watcher GenServer, Actor hook, OrphanJanitor |
| L (4-8h) | 0 | — |
| ≥ 8h | 0 | None — all tasks are granular and reviewable in isolation |

Estimates are conservative; the synchronous hook (TRD-007-TASK) and the compensation path (TRD-008-TASK) are the most complex items, but each is a single 2-4h task with a single test pairing. The watcher single-cursor invariant (TRD-011-TASK) and pipeline (TRD-012-TASK) are well-scoped thanks to the 3-way cursor priority + Option A in AC-022-1.

---

## Testability Review

| Implementation AC | Testability | Notes |
|---|---|---|
| AC-020-1 happy path | Verifiable via state-after-step assertion on a stubbed Actor harness; mock `BrRunner` returns `{:ok, %{"id" => "foreman-abc", ...}}`; assert `send CommandRouter, {:append, aggregate_id, [event_data], expected_version, ref, self()}` was invoked with `external_id == "foreman-abc"` in the normalized event data; on `receive {:append_ok, ^ref, count, …}` assert `commit_event/3` was called and `state.version` was bumped | TRD-007-TEST scenario 1 |
| AC-020-2 round-trip | Verifiable via `ProjectionStore.get_task(external_id: bead_id)` (keyword arity, `/1`) returning the task map with `external_id`; `GET /api/tasks/:id` integration test | TRD-010-TEST scenarios 3, 4 |
| AC-020-3 compensation | Verifiable via CommandRouter stub that returns `:wrong_expected_version` once then `:ok`; assert `BeadsAdapter.create/2` is NOT called on retry; assert `in_flight_beads` is preserved across `reload_after_conflict/1` (cache hit poisons the retry path); assert eventual `TaskCreated` event has `external_id: bead_id`; bounded-retry exhaustion → `BeadsAdapter.complete/3` with `transition_comment: "foreman-compensation:append-conflict-retry-exhausted"` | TRD-008-TEST scenarios 1, 2, 3, 4 |
| AC-020-4 non-Beads project | Verifiable via Mox stub that returns a capability map without `:create`; assert the hook is a no-op and `external_id` remains `nil` | TRD-007-TEST scenario 2 |
| AC-020-5 failure-as-error | Verifiable via Mox stub that returns `{:error, %ProviderError{code: "INVALID_TITLE"}}`; assert the Actor returns the error from `do_dispatch/4` WITHOUT `normalize_to_event_data` or `send CommandRouter, {:append, …}` | TRD-007-TEST scenario 3 |
| AC-020-6 watcher-import | Verifiable via synthetic envelope via `dispatch_system/2`; assert `BeadsAdapter.create/2` is NOT invoked; assert bead ID is preserved | TRD-007-TEST scenario 4 |
| AC-020-7 boundary invariant | Verifiable via `dispatch_operator/2` unit test asserting `task.create` with non-nil `external_id` is REJECTED at the allowlist | TRD-009-TEST scenarios 1, 2, 3 |
| AC-021-1 tag shape | Verifiable via argv assertion on Mox; the exact `--agent-context` JSON is captured and parsed | TRD-003-TEST scenario 2 |
| AC-021-2 foreman-tag check | Verifiable via JSONL fixture with foreman-tagged and untagged beads; assert watcher suppresses foreman-tagged; janitor closes foreman-tagged orphans | TRD-012-TEST scenario 1; TRD-013-TEST scenarios 2, 3, 4 |
| AC-021-3 ISO8601 + origin | Verifiable via JSON parse of the captured argv | TRD-003-TEST scenario 2 |
| AC-022-1 single-cursor invariant | Verifiable via 3 JSONL fixture scenarios: tail-mode transient; boot-mode transient; boot-mode fragment | TRD-011-TEST scenarios 9, 10, 11 |
| AC-022-2 dedupe | Verifiable via ProjectionStore stub returning a hit; assert no-op | TRD-012-TEST scenario 2 |
| AC-022-3 suppression | Verifiable via JSONL fixture with foreman-tagged bead; assert skip + telemetry | TRD-012-TEST scenario 1 |
| AC-022-4 opt-in | Verifiable via supervisor test asserting child presence/absence based on flag | TRD-014-TEST scenarios 1, 2 |
| AC-023-1 grace window | Verifiable via timing mock; assert no scan before grace; assert scan after grace | TRD-013-TEST scenario 1 |
| AC-023-2 case (a) | Verifiable via ProjectionStore stub returning no task; assert close with `"foreman-orphan:no-task"` | TRD-013-TEST scenario 2 |
| AC-023-3 case (b) | Verifiable via ProjectionStore stub returning task in `closed` / `failed`; assert close with `"foreman-orphan:terminal-task"` | TRD-013-TEST scenario 3 |
| AC-023-4 non-foreman skip | Verifiable via JSONL fixture with untagged bead; assert `BeadsAdapter.complete/3` is NOT called | TRD-013-TEST scenarios 4, 5 |
| AC-024-1 cache hit | Verifiable via state-after-step assertion; replay the same `command_id`; assert second call uses cached bead ID | TRD-007-TEST scenario 5; TRD-006-TEST |
| AC-024-2 cache clear on terminal | Verifiable via state-after-step; assert cache cleared after `{:append_ok, count}`; assert NOT cleared on transient | TRD-006-TEST; TRD-008-TEST |
| AC-024-3 process-local | Verifiable via Actor crash simulation; assert cache is empty after restart | TRD-006-TEST |
| AC-024-4 concurrent `command_id`s | Verifiable via two concurrent `Task.async` calls; assert each cache entry is distinct | TRD-007-TEST scenario 7 |
| AC-025-1 projection | Verifiable via ProjectionStore test | TRD-010-TEST scenarios 1, 2 |
| AC-025-2 capabilities | Verifiable via unit test on `BeadsAdapter.capabilities/0` | TRD-002-TEST |
| AC-025-3 callback count | Verifiable via `behaviour_info(:callbacks)` length assertion | TRD-001-TEST |
| AC-026-1..5 CodeMap rows | Verifiable via 5 scenario tests on `CodeMap` with Mox returning the corresponding `br` envelope | TRD-004-TEST scenarios 1-5 |

All implementation ACs are objectively verifiable. No subjective language (fast, good, user-friendly) appears in the ACs; all ACs have specific pass/fail criteria.

---

## Design Readiness Gate

| Dimension | Score (1-5) | Notes |
|---|---|---|
| Completeness | 4 | All 7 PRD requirements have ≥ 1 implementation task and ≥ 1 test task. 30 PRD ACs map to master tasks across the implementation/test pairs. Architecture options A/B/C are documented; Option C is justified. Slice invariant preserved end-to-end. CommandGateway boundary invariant and watcher single-cursor invariant are named and mapped to existing enforcement points. |
| Testability | 4 | All 30 implementation ACs are objectively verifiable via the test tasks. State-after-step assertions on a stubbed Actor harness. Mox stubs for `BrRunner` and `BeadsAdapter.complete/3` are the primary test mechanism. JSONL fixtures exercise the watcher's 3-way cursor priority under transient, fragment, and boot scenarios. No subjective language. |
| Clarity | 4 | The two-stage aggregate finalization contract is documented with four explicit stages. The Actor hook insertion point (`do_dispatch/4` between `handle_command/2` and `normalize_to_event_data`) is named. The single-event design (`TaskCreated.external_id`) is named in §2.1.3 and §2.2.6. The `CommandGateway` boundary invariant is named in §2.2.6 item 4. The in-flight cache is named in §2.2.6 item 3. The watcher single-cursor invariant is named in §2.2.6 item 6 with the 3-way cursor priority. |
| Feasibility | 4 | All `br` commands cited were observed at version 0.2.19 (PRD §2.2). The synchronous hook's worst-case latency is bounded by `PRD-2026-48f7b420` REQ-009-2 (30s default). The orphan janitor's grace window is configurable to absorb boot-time append latency. The projection map extension is a 1-line addition. The two opt-in supervisor flags mirror the existing `JsonSchemaCache` / `ProjectProviderProjector` pattern. |

**Overall: 4.0 — READY FOR IMPLEMENTATION.**

**Gate decision: READY FOR IMPLEMENTATION.** All 7 PRD REQs are mapped to 15 implementation tasks + 15 paired test tasks + 1 docs-only task. The dependency graph is acyclic and bounded. The compensating-consistency contract (synchronous in-process all-or-nothing for the normal path with the orphan janitor + `br close` compensation closing the residual gap within the configurable grace window) is the design's central commitment, and every code path has a named recovery mechanism (compensation, janitor, supervisor restart). The CommandGateway boundary invariant (`dispatch_operator/2` rejects `task.create` with non-nil `external_id`; system dispatch is the only path that can supply a pre-existing `external_id`) is a hard prerequisite (AC-020-7) enforced at the existing envelope allowlist. The slice invariant (`every emitted event is owned by an aggregate's handle_command/2; no module fabricates events`) is preserved end-to-end. The slice is ready for implement-trd-beads.

---

## Traceability Validation

```
Traceability check: 7 requirements covered, 0 uncovered, 0 orphaned annotations
Requirement coverage: REQ-020 (5 impl tasks, 5 test tasks), REQ-021 (1 impl, 1 test), REQ-022 (3 impl, 3 test), REQ-023 (2 impl, 2 test), REQ-024 (3 impl, 3 test), REQ-025 (3 impl, 3 test), REQ-026 (2 impl, 2 test).
AC coverage: 30/30 (100%).
Task count: 31 master entries (15 implementation + 15 paired test + 1 docs-only).
PR count: 3.
```

**Zero uncovered PRD requirements.** **Zero orphaned `[satisfies REQ-NNN]` annotations.**

---

## Risks and Open Questions

### Risks

1. **Synchronous `br create` latency.** Each `task.create` now incurs a `br` subprocess round-trip inside the Actor hook. **Mitigation:** bounded by `PRD-2026-48f7b420` REQ-009-2 (30s default); compensation (AC-020-3) handles append-conflict; orphan janitor (REQ-023) handles cron-drop; latency is on the create path only.
2. **Actor crash between bead creation and append.** If the Actor crashes after `BeadsAdapter.create/2` returns success but before receiving `{:append_ok, ^ref, count, …}` from CommandRouter, the bead is on disk in Beads but no Foreman task exists. **Mitigation:** REQ-023 orphan janitor picks up the bead on its grace-window scan (default 300s). AC-024-3 makes the in-flight cache process-local; the janitor is the recovery path.
3. **Watcher-storm scenario (boot replay).** On every boot, the watcher reads the entire JSONL from offset 0. **Mitigation:** AC-022-2 dedupe makes the steady-state replay cost ~1 read + 1 short ProjectionStore lookup per line. Telemetry `[:watcher, :replay_started]` / `[:watcher, :replay_completed]` carries counters for sizing. A future ops decision is to add a JSONL compaction step or a streaming FSEvents watcher.
4. **Tag-spoofing risk.** A Beads CLI operator could theoretically write `agent_context.foreman` themselves. **Mitigation:** the orphan janitor (REQ-023) is the safety valve — a spoofed-tagged bead is closed only if no corresponding Foreman task exists with `external_id == bead.id` after the grace window.

### Open Questions

None — all 3 PRD ambiguity markers are resolved (see PRD §5).

### Known out-of-scope gaps (not blocking v1)

1. **No streaming watcher upgrade.** REQ-022 polls the JSONL on a 2s tick. A `:file.inotify` / FSEvents-based tail would reduce steady-state latency but is not portable and adds a dep. Deferred.
2. **No multi-project scan optimisation.** The orphan janitor (REQ-023) and watcher (REQ-022) iterate registered projects independently. A shared scanner with one tail per `.beads/` directory and per-project routing would reduce resource usage on N-project deployments. Deferred.
3. **No `foreman bead audit` CLI.** A future PRD will add a CLI surface to look up bead ID → task ID → run ID → command_id. Deferred.
4. **No `task.update` integration.** The PRD does not add `external_id` mutation paths through the operator surface. A future PRD will reconcile task-title changes, priority changes, and dependency adds against Beads. Deferred.
5. **No interactive UI for orphan conflict resolution.** The janitor closes beads automatically when the linked task is `closed` / `failed`. A future PRD will add an `OrphanHoldQueue` for operator review. Deferred.

---

## Files Touched (when implemented)

This TRD is the **design contract only**. Implementation will add:

- `packages/foreman_server/lib/foreman_server/task_providers/beads_watcher.ex` — supervised GenServer; one tail process per registered project
- `packages/foreman_server/lib/foreman_server/task_providers/beads_orphan_janitor.ex` — supervised GenServer; one scanner per registered project
- Additions to `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter.ex` — new `create/2` callback implementation; `capabilities/0` extended to advertise `:create`; argv-construction helpers; pre-emptive Foreman-side validation
- Additions to `packages/foreman_server/lib/foreman_server/task_provider.ex` — new `@callback create/2` declaration (callback count grows 11 → 12)
- Additions to `packages/foreman_server/lib/foreman_server/aggregate/actor.ex` — two-stage aggregate finalization in `do_dispatch/4`; `in_flight_beads: %{command_id => bead_handle}` state field; pre-populated `external_id` skip branch (AC-020-6); compensation path (AC-020-3)
- Additions to `packages/foreman_server/lib/foreman_server/command_gateway.ex` — `dispatch_operator/2` rejects `task.create` with non-nil `envelope.payload.external_id` at the allowlist guard (AC-020-7); `dispatch_system/2` is unchanged
- Additions to `packages/foreman_server/lib/foreman_server/projection_store.ex` — `TaskCreated` task map extended with `external_id` (no new event handler)
- Additions to `packages/foreman_server/lib/foreman_server/event_codec.ex` — NO changes; `external_id` is an existing optional field on `TaskCreated`
- Additions to `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter_code_map.ex` — five new rows (`INVALID_TITLE`, `INVALID_PRIORITY`, `INVALID_ISSUE_TYPE`, `DUPLICATE_TASK_ID`, `CREATE_FAILED`)
- Additions to `packages/foreman_server/lib/foreman_server/task_providers/registry.ex` — `route/2` dispatches `:create` to the same per-project state
- Additions to `packages/foreman_server/lib/foreman_server/application.ex` — two `maybe_*_child/0` helpers (`maybe_beads_watcher_child/0`, `maybe_beads_orphan_janitor_child/0`); flags `:start_beads_watcher?` / `:start_beads_orphan_janitor?` (default `false`)
- Additions to `packages/foreman_server/config/test.exs` — both flags set to `false`
- Additions to `packages/foreman_server/config/runtime.exs` — document the flags
- Additions to `packages/foreman_server/test/foreman_server/task_provider_test.exs` — `length(callbacks) == 12` (lines 12 and 24); `assert {:create, 2} in callbacks`
- `packages/foreman_server/test/foreman_server/task_providers/beads_adapter_create_test.exs` — REQ-020 + REQ-021 happy path + 5 CodeMap rows
- `packages/foreman_server/test/foreman_server/task_providers/beads_adapter_code_map_test.exs` — 5 CodeMap row routing
- `packages/foreman_server/test/foreman_server/task_providers/registry_test.exs` — `:create` routing
- `packages/foreman_server/test/foreman_server/aggregate/actor_in_flight_cache_test.exs` — cache state, init, process-local semantics
- `packages/foreman_server/test/foreman_server/aggregate/actor_hook_test.exs` — 7 scenarios covering AC-020-1, AC-020-4, AC-020-5, AC-020-6, AC-024-1, AC-024-2, AC-024-4
- `packages/foreman_server/test/foreman_server/aggregate/actor_compensation_test.exs` — 4 scenarios covering AC-020-3
- `packages/foreman_server/test/foreman_server/command_gateway_external_id_guard_test.exs` — AC-020-7 boundary rejection
- `packages/foreman_server/test/foreman_server/projection_store_task_external_id_test.exs` — AC-025-1 round-trip
- `packages/foreman_server/test/foreman_server/task_providers/beads_watcher_test.exs` — boot replay + tail mode + 3-way cursor priority + 11 scenarios
- `packages/foreman_server/test/foreman_server/task_providers/beads_watcher_pipeline_test.exs` — 6 scenarios covering AC-022-2, AC-022-3
- `packages/foreman_server/test/foreman_server/task_providers/beads_orphan_janitor_test.exs` — 5 scenarios covering AC-023-1, AC-023-2, AC-023-3, AC-023-4
- `packages/foreman_server/test/foreman_server/application_supervisor_test.exs` — 4 opt-in flag scenarios
- `docs/user-guide.md`, `docs/cli-reference.md`, `README.md`, `CLAUDE.md` — per `foreman-doc-gate` skill

No existing test, projection, or aggregate code is modified without a documented reason tied to a REQ above.

---

## Changelog
### 1.0.7 — 2026-08-11 (ProjectionStore.get_task arity correction)

- **Stale arity typo correction.** Two TRD rows referenced `ProjectionStore.get_task/2` as if it were a positional 2-arity call, but the only concrete call sites in the spec — the Beads watcher dedupe path (TRD line 206 and the TRD-011-TEST spec at line 449) — use the keyword form `ProjectionStore.get_task(external_id: bead.id)`. The `/2` label was a stale typo from an earlier draft that defined a project-scoped lookup and was never updated when the design collapsed to a single-keyword lookup.
- **Rows updated.** TRD-010-TEST spec (line 435) and the AC-020-2 traceability row (line 690) now read `ProjectionStore.get_task(external_id: bead_id)` with an explicit `(keyword arity, /1)` annotation.
- **Implementation already matches.** `ProjectionStore.get_task/1` (keyword arity) was implemented as part of the TRD-010-TASK reopen in commit `e69ad7a5`; the test suite (`projection_store_task_external_id_test.exs` scenario 3) exercises the keyword form directly. No PRD mirror changes required — the PRD §4 row never carried the `/2` typo.
- **No AC / task count changes:** 7 REQs / 30 ACs / 31 tasks / 3 PRs unchanged.

### 1.0.6 — 2026-08-11 (working-tree cascade: 4 architecture redesigns + cycle fix + TRD-016 insertion)

- **Scope.** This entry consolidates ALL working-tree changes that diverge from origin's `1.0.5`. The branch went through four architectural redesigns during a single session, plus a dependency-cycle fix, plus the insertion of TRD-016. Origin's `1.0.0`–`1.0.5` entries are preserved verbatim below this entry; the working tree's `1.0.0`–`1.0.3` cascade entries have been collapsed into this single `1.0.6` entry to avoid factually-impossible claims about divergent task counts (origin's `1.0.4`/`1.0.5` describe 24 tasks across 3 PRs; the working tree's `1.0.6` describes 31 tasks across 3 PRs).

- **Architecture redesign #1 — Actor↔CommandRouter append/ack protocol.** Stage 4 of the two-stage `do_dispatch/4` finalization hook now uses the EXISTING Actor↔CommandRouter append/ack protocol (`send CommandRouter, {:append, aggregate_id, [event_data], expected_version, ref, self()}` → `receive {:append_ok, ^ref, count, append_latency_ms}` → `commit_event/3` which calls `aggregate.apply_event/2` and bumps `state.version`). The Actor NEVER calls `EventStore.append_to_stream/3` directly — that is the architectural invariant the existing architecture test enforces. Section updates: §2.1.3 Stage 4, §2.2.2 Data Flow Stage 4, §2.2.3 Watcher Stage 4, §2.2.4 Error Paths rows 1–4, §2.2.5 Reused Capabilities `do_dispatch/4` and bounded-retry rows, §2.2.6 Architecture Decision #2 (re-numbered), TRD-007-TASK Stage 4 + Action #5, TRD-007-TEST scenarios 1/5/6, TRD-008-TASK compensation path, TRD-008-TEST scenarios 1–4, AC-020-3/AC-020-5 traceability rows. `in_flight_beads` cache preservation through `reload_after_conflict/1` is documented: the existing `rehydrated = %{state | module_state: …, version: …}` pattern preserves the cache, so the retry path hits the cache, skips a second `BeadsAdapter.create/2`, and re-runs stage 3 with the cached `external_id`.

- **Architecture redesign #2 — TaskProvider.Registry.project_config/1 helper.** `BeadsAdapter.create/2` resolves the per-project `database_path` via `Registry.project_config(project_id)` as its first line. The helper's return shape is `{:ok, %{provider_module: module(), config: map()}} | {:error, atom()}` where `config` carries `:database_path`. The 3-case match in `handle_call({:project_config, project_id}, …)` mirrors the existing `route_provider/3` for `{project_id, database_path}` and returns `:task_provider_not_configured` / `:provider_unavailable_for_project` for the same failure modes (without the `database_path_mismatch` cross-check, which is a `route/2` concern). `BeadsAdapter.create/2` propagates a `Registry.project_config/1` failure as terminal `CREATE_FAILED` (non-retryable) — no retry loop on registry failure.

- **Architecture redesign #3 — Canonical 7-key attrs map (Option B).** `BeadsAdapter.create/2` accepts a single `attrs` map whose keys are FIXED at the boundary: `%{task_id :: String.t(), command_id :: String.t(), title :: String.t(), description :: String.t() | nil, priority :: non_neg_integer(), task_type :: String.t(), dedupe_key :: String.t() | nil}`. Both correlation handles (`task_id`, `command_id`) live INSIDE `attrs` (PRD AC-020-1, AC-021-3 trace both to this map; PRD 2-arity `create(project_id, attrs)` signature preserved). Missing any required key at the call site is a pre-emptive validation failure routed to the appropriate CodeMap row before argv construction. `source_repo` is a derived field on `%TaskProvider.Issue{}`, NOT a key on `attrs`. `dedupe_key` is preserved on `attrs` for future-extension `--dedupe-key` argv flag. `description` is `String.t() | nil` on `attrs` — `nil` is the operator-omitted-description case. **No `:agent_context` key on `attrs`** — the `agent_context` JSON payload is CONSTRUCTED in the `attrs → runner-payload` transform boundary (TRD-003 Action #5).

- **Architecture redesign #4 — Runner boundary contract.** The `BrRunner` behaviour is `cmd(request, project_config, opts)` (`br_runner.ex:28-30`); `BrRunner.run/1` does not exist and is NOT introduced. ALL argv construction is owned by `SystemBrunner`. The dedicated `build_action_argv(:create, payload)` clause in `SystemBrunner` MUST call `validate_payload_shape!(:create, payload)` FIRST (line 1 of the body), mirroring the existing `:set_priority` pattern at `system_br_runner.ex:176-185`; the default `tap`-deferred validator at line 198-204 only works for `:flags`-extracted actions and would crash with `KeyError` / `Protocol.UndefinedError` on direct `payload.field` access. **Runner-payload is SUBSIDIARY to the canonical attrs map**: the 6-step transform at TRD-003 Action #5 normalises `attrs → payload`, performing the one rename (`attrs.task_type → payload.type`), one normalisation (`nil → ""` on description), and one construction step (build `agent_context` JSON with `foreman: %{task_id: task_id, command_id: command_id, origin: "foreman", linked_at: iso8601_utc_now()}`). Action-specific argv order: `["--title", payload.title, "--type", payload.type, "--priority", Integer.to_string(payload.priority), "--description", payload.description, "--agent-context", payload.agent_context] |> maybe_append_json_flag()`. The `project_config` passed to `BrRunner.cmd/3` is the `:config` map from `Registry.project_config/1`.

- **TRD-016 inserted (29 → 31 master entries).** New implementation + paired-test task extending `SystemBrunner` with a dedicated `:create` clause. Total master entries grow from 29 (in 1.0.0–1.0.3 cascade baseline) to 31: 15 implementation tasks + 15 paired test tasks + 1 docs-only task. PR 1 grows from 10 → 12 entries (TRD-001–TRD-005 + TRD-016).

- **Dependency cycle fix.** `TRD-003-TASK [depends: TRD-004-TASK]` AND `TRD-004-TASK [depends: TRD-003-TASK]` declared a direct cycle. Removed the back-edge `[depends: TRD-003-TASK]` from `TRD-004-TASK`. Topological rationale: `TRD-004-TASK` (CodeMap rows for `INVALID_TITLE`, `INVALID_PRIORITY`, `INVALID_ISSUE_TYPE`, `DUPLICATE_TASK_ID`, `CREATE_FAILED`) must exist before `TRD-003-TASK` (`BeadsAdapter.create/2`) because `create/2` emits CodeMap rows on validation failures. The corrected graph is acyclic:
  - Level 1: TRD-001, TRD-004, TRD-006, TRD-013, TRD-016 (no deps)
  - Level 2: TRD-002 (←TRD-001), TRD-011 (←TRD-016)
  - Level 3: TRD-003 (←TRD-001, TRD-002, TRD-004), TRD-012 (←TRD-011)
  - Level 4: TRD-005 (←TRD-001, TRD-003), TRD-014 (←TRD-012, TRD-013)
  - Level 5: TRD-007 (←TRD-003, TRD-005, TRD-006), TRD-015 (←TRD-014)
  - Level 6: TRD-008, TRD-009, TRD-010 (←TRD-007)
  Critical path: TRD-001 → TRD-002 → TRD-003 → TRD-005 → TRD-007 → TRD-008 = 6 hops.

- **REQ coverage (verified):** REQ-020 → TRD-003, TRD-005, TRD-007, TRD-008, TRD-009, TRD-016; REQ-021 → TRD-003, TRD-016; REQ-022 → TRD-011, TRD-012, TRD-014; REQ-023 → TRD-013, TRD-014; REQ-024 → TRD-006, TRD-007, TRD-008, TRD-011; REQ-025 → TRD-001, TRD-002, TRD-005, TRD-010; REQ-026 → TRD-003, TRD-004, TRD-016.

- **Frontmatter:** `version: 1.0.5` → `1.0.6`. `total_tasks: 24` → `31`. `total_requirements: 7`, `total_acceptance_criteria: 30` unchanged.

- **No code reverted.** None of origin's `1.0.0`–`1.0.5` design decisions (e.g. AC-022-1's 3-way cursor priority, AC-020-5's failure-contract fix, REQ-024's in-flight cache semantics, the `BeadsAdapter.recognise_foreman_tag/1` helper for `foreman doctor task_provider`, the `BeadsWatcher` boot-replay + dedupe contract) is undone. The working tree's changes are purely additive at the architectural level — they tighten the runner boundary contract and pin the registry / adapter / argv-construction seams that origin's earlier entries left abstract.

- **Why this entry collapses 1.0.0–1.0.3 of the working tree.** Origin's `1.0.0`–`1.0.5` history describes a coherent progression (8 REQs → 7 REQs; 31 ACs → 30 ACs; 20 tasks → 24 tasks across 4 → 3 PRs). The working tree diverged from origin at every version: 7 REQs / 30 ACs / 29 → 31 tasks / 3 PRs. Recording the working tree's `1.0.0`–`1.0.3` entries separately (as the previous version of this file did) made it factually impossible: e.g. `1.0.3` (2026-08-11, working tree) said "29 → 31 tasks" while `1.0.4`/`1.0.5` (2026-08-10, origin) said "Counts unchanged: 7 requirements, 30 ACs, 24 tasks" — but the working tree never had `1.0.4`/`1.0.5` entries of its own, and origin's `1.0.4`/`1.0.5` describe 24 tasks in a state the working tree never reached. This entry records all of the working tree's changes in a single coherent block; origin's `1.0.0`–`1.0.5` entries follow it unchanged.

### 1.0.5 — 2026-08-10 (3-way cursor priority for boot + tail-mode read)

- **Advisory #22 (blocker) — single-cursor invariant.** The earlier tail-buffer design (`read_offset` advances past fragment bytes; `partial_line` cleared on transient dispatch; next poll prepends `partial_line`) carries a subtle transient-dispatch duplication bug at the exact poll boundary where a complete line spans a fragment + new bytes AND the dispatch is transient: the next poll re-reads the fragment bytes from the advanced `read_offset` while `partial_line` is empty, so the fragment is dropped on the next transient retry (or duplicated if the next poll also reads past the line break). The 1.0.5 cascade replaces the trailing-line buffer with a single-cursor invariant: `read_offset` is the byte position of the next NEW byte to read and HOLDS at the seat of any fragment line; `partial_line` is a cached copy of the last split segment (NOT including the trailing `\n`), kept for observability only; the next poll reads only the new bytes from `read_offset` (no prepending); on a terminal dispatch `read_offset` is moved past `byte_size(line) + 1`; on a transient dispatch `read_offset` is held and the loop stops (the fragment remains seated and is re-read on the next poll, preserving ordering without prepending). The exhaustive terminal set (advisory #19) and the wrapper-shape classifier (advisory #20) are unchanged.

- **§2.2.2 BeadsWatcher description (line 194, `:read_more` paragraph):** "prepends any `partial_line` buffer" replaced with "do NOT prepend `partial_line`"; the "on the LAST line without a trailing newline stores the partial bytes in `partial_line` and DOES NOT advance `read_offset` past them" clause replaced with the explicit single-cursor invariant (`read_offset` HOLDS at fragment seat; `partial_line` is `last_segment` cache; advance only on terminal past `byte_size(line) + 1`; transient holds `read_offset` and stops the loop).

- **§3 TRD-016-TASK row (line 458):** "seek to `read_offset`, read bytes to current EOF, prepend `partial_line` buffer, split on newlines" → "seek to `read_offset`, read bytes to current EOF (do NOT prepend `partial_line`), split on newlines"; the "Trailing-line buffer" clause rewritten to the single-cursor invariant.

- **§3 TRD-021-TASK row (line 463):** "trailing-line buffer carries a partial line across poll boundaries without advancing `read_offset` past it" replaced with the single-cursor test assertion: `read_offset` holds at fragment seat, fragment is re-read on next poll (no prepending), `partial_line` is `last_segment` (observability only), terminal advance moves `read_offset` past `byte_size(line) + 1`, transient holds `read_offset`.

- **§5 AC-022-1 row (line 510):** Tail-mode test now asserts the single-cursor invariant end-to-end: poll reads from `read_offset` to EOF (the fragment at the seat, if any, is part of the read result and is re-read on transient retries; no prepending); terminal advance moves `read_offset` past `byte_size(line) + 1`; transient holds `read_offset` and the fragment is re-read on the next poll (no duplication, no loss). The boot fragment retention scenario is added separately (see Advisory #23 below).

- **Frontmatter (line 4):** `version: 1.0.4` → `1.0.5`. Counts unchanged: 7 requirements, 30 ACs, 24 tasks.
- **Advisory #23 (blocker) — boot fragment retention + read-cursor wording.** The 1.0.5 cascade revised the tail-mode read invariant to a single-cursor model, but the boot replay description still said "captures the byte offset of the end-of-file as the tail-mode `read_offset` start" — which loses any unterminated JSONL fragment at the end of the file (the fragment is never processed, and the next poll would seek past it). The boot replay now uses the same single-cursor invariant as `:read_more`: on completion, `read_offset` is set to the byte position of the START of any unterminated JSONL fragment (or the file size if the file ends on a terminator) and `partial_line` is the cached fragment bytes (or `""`). The wording "read only the new bytes from `read_offset`" is replaced with "read from `read_offset` to EOF" (the next uncommitted-line cursor), since transient retries intentionally re-read bytes already scanned (the fragment at the seat is part of the read result).

- **§2.2.2 BeadsWatcher description (line 194, `init/1` + `On :read_more` paragraphs):** the "Captures the byte offset of the end-of-file as the tail-mode `read_offset` start" clause replaced with a new "Boot cursor semantics" paragraph that explicitly sets `read_offset` to the fragment START (or file size) and `partial_line` to the cached fragment (or `""`); the "On `:read_more` (single-cursor invariant)" paragraph's "next NEW byte to read" wording replaced with "next uncommitted-line cursor" and the "read only the new bytes from `read_offset`" step replaced with "read from `read_offset` to EOF" (the fragment at the seat is part of the read result and is re-read on transient retries).

- **§3 TRD-015-TASK row (line 457):** "capture EOF as tail-mode `read_offset`" → "set `read_offset` to the byte position of the START of any unterminated JSONL fragment (or the file size if the file ends on a terminator) and `partial_line` to the cached fragment bytes (or `""` if the file ends on a terminator)".

- **§3 TRD-021-TASK row (line 463):** "tail mode captures EOF and subsequent `:read_more` only processes new lines" → "tail mode captures the boot-completion cursor (fragment seat or file size) and subsequent `:read_more` reads from `read_offset` to EOF"; added a new "boot fragment retention test" scenario with an unterminated-fragment fixture and the boot→tail-mode recompletion assertion.

- **§5 AC-022-1 row (line 510, post-Advisory #24):** the tail-mode-test clause "reads ONLY the new bytes from `read_offset`" replaced with "reads from `read_offset` to EOF (the transient-line or fragment at the seat, if any, is part of the read result and is re-read on transient retries; no prepending)"; the `read_offset` advance wording upgraded to the 3-way cursor priority + Option A single-cursor invariant; added a new "Boot fragment retention test" scenario with an unterminated-fragment fixture and the boot→tail-mode recompletion assertion (the **boot transient retention test** scenario — transient complete-line followed by N queued complete-lines with `read_offset` HOLDS at the transient-line start, no skipping of queued lines — is added separately by Advisory #24).
- **Advisory #24 (blocker) — 3-way cursor priority for boot + tail-mode read (Option A).** The 1.0.5 single-cursor invariant (Advisories #22 + #23) described a 2-way priority: `read_offset` HOLDS at the seat of any fragment line (or EOF), `partial_line` is the cached `last_segment`. This carries a subtle transient-dispatch ordering bug: when the loop stops at a transient complete-line and queued complete-lines follow it on disk, the next poll would seek past the transient-line seat IF `partial_line` were only the trailing fragment bytes (which is empty when the file ends on a terminator). The 1.0.5 cascade upgrades to a 3-way cursor priority + Option A: `read_offset` is the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED — (a) the start byte of the first transient complete-line if the loop stopped at a transient; (b) the start byte of any trailing fragment if the file ends on an unterminated JSONL line; (c) the file size (EOF) if the file ends on a terminator. `partial_line` is the bytes of the FIRST LINE NOT TERMINALLY DISPATCHED — transient-line bytes from the split, trailing fragment bytes from `last_segment`, or `""` respectively (observability only, NOT required for correctness). With Option A, transient retries re-read the transient complete-line at `read_offset`, dispatch with the same deterministic `command_id`, and queued lines behind the transient are NOT skipped.

- **§2.2.2 BeadsWatcher description (line 194, `init/1` + `On :read_more` paragraphs):** the "Boot cursor semantics" paragraph upgraded from 2-way (fragment-or-EOF) to 3-way cursor priority (first transient complete-line, trailing fragment start, or EOF); the `partial_line` clause upgraded from `last_segment` cache to bytes of the FIRST LINE NOT TERMINALLY DISPATCHED (transient-line bytes, trailing fragment bytes, or `""` respectively). The `:read_more` step (5) reworded — the transient complete-line (NOT the fragment) is seated at `read_offset` and is re-read on the next poll with the same deterministic `command_id`. The `:read_more` step (6) reworded — `partial_line` derives from the FIRST LINE NOT TERMINALLY DISPATCHED (transient-line bytes, trailing fragment bytes, or `""` respectively).

- **§3 TRD-016-TASK row (line 458):** the "Trailing-line buffer (single-cursor invariant)" clause upgraded from 2-way (`read_offset` HOLDS at fragment seat; `partial_line` is `last_segment`) to 3-way cursor priority + Option A (`read_offset` HOLDS at the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED — first transient complete-line, trailing fragment start, or EOF; `partial_line` is the bytes of that first undispatched line — transient-line bytes, trailing fragment bytes, or `""` respectively).

- **§3 TRD-021-TASK row (line 463):** the single-cursor invariant test assertion upgraded from 2-way to 3-way cursor priority + Option A. Added a new **boot transient retention test** scenario: fixture contains a transient complete-line followed by N queued complete-lines (e.g. `{"id":"bead-3",...}\n{"id":"bead-4",...}\n{"id":"bead-5",...}\n`); the watcher boots, dispatches `bead-3`, and the dispatch returns transient (e.g. `{:error, %ProviderError{retryable?: true, code: "BR_TIMEOUT_SUBPROCESS"}}`); the loop stops at the transient, `read_offset` HOLDS at `bead-3`'s start byte (NOT advanced to `bead-4`'s start), `partial_line` is the cached bytes of `bead-3`; subsequent `:read_more` polls re-read from `read_offset` and re-attempt `bead-3` with the same deterministic `command_id`; once the transient resolves to a terminal, the watcher advances `read_offset` past `bead-3` and dispatches `bead-4` and `bead-5` — lines 4..5 are NOT skipped or duplicated.

- **§5 AC-022-1 row (line 510):** the single-cursor invariant end-to-end assertion upgraded from 2-way to 3-way cursor priority + Option A. Added the **boot transient retention test** scenario (same as TRD-021-TASK above). The AC title upgraded to mention `3-way cursor priority + boot fragment retention + boot transient retention`.

- **Frontmatter (line 4):** `version: 1.0.5` unchanged. Counts unchanged: 7 requirements, 30 ACs, 24 tasks. Header line updated to "3-way cursor priority for boot + tail-mode read".

### 1.0.4 — 2026-08-10 (terminal-set explicit + wrapper-shape fix)
- **Advisory #19 (blocker) — terminal set made explicit.** The 1.0.3 §2.2.2 paragraph and TRD-016-TASK row referred to "success or known-rejected terminal error" — undefined shorthand. The 1.0.4 cascade replaces this with an EXHAUSTIVE terminal set aligned to PRD §4 AC-022-1 verbatim: `{:ok, _}` plus the four aggregate domain rejections wrapped by the gateway — `{:error, {:already_exists, :task, _}}`, `{:error, {:invalid_task_status, _}}`, `{:error, {:project_archived, _}}`, `{:error, :project_id_required}`. Every other gateway return is transient. `ProviderError` is NEVER produced by the watcher-import branch because that branch dispatches via `CommandGateway.dispatch_system/2` and bypasses `BeadsAdapter.create/2` (per AC-020-6); `ProviderError` is mentioned only in the transient list as forward-compatibility scaffolding.
- **Advisory #20 (blocker) — wrapper-shape correctness.** The 1.0.3 wording treated the four terminal atoms as equal-shape, but the gateway wraps each inner reason in `{:error, _}`. The 1.0.4 cascade updates §2.2.2 paragraph, §3 TRD-016-TASK row, and §5 AC-022-1 row to use arity-distinct wrapped patterns (`{:error, {:already_exists, :task, _}}` vs `{:error, {:invalid_task_status, _}}` vs `{:error, {:project_archived, _}}` vs `{:error, :project_id_required}`) and to specify that the classifier pattern-matches the FULL gateway return shape (outer wrapper preserved, inner reason matched by arity). Test plan in §5 AC-022-1 row specifies each Mox stub returns the wrapped shape, not the bare reason.
- **§2.2.2 paragraph (line 194, "BeadsWatcher" description):** "success or known-rejected terminal error" replaced with explicit cross-reference to the §2.2.2 paragraph below for the exhaustive terminal set, naming all four wrapped shapes.
- **§3 TRD-016-TASK row (line 453):** terminal-set reference rewritten with explicit 5-arm classifier (`{:ok, _}` + four wrapped error arms + fallback transient), each pattern arity-distinct.
- **§5 AC-022-1 row (line 504):** Notes column rewritten to specify Mox stubs return wrapped shapes; complementary transient tests for `ProviderError{retryable?: true, code: "BR_TIMEOUT_SUBPROCESS"}`, `{:error, {:wrong_expected_version, 5, 6}}`, and `{:exit, :killed}`. Forward-compatibility note explicitly marks `ProviderError` synthetic test as defensive scaffolding only.
- **§2.2.4 Issues list (issue #7 added):** new architectural invariant — "Watcher terminal-vs-transient dispatch classification is EXHAUSTIVE" — referencing the §2.2.2 paragraph by name and codifying the wrapper-shape pattern-matching requirement.
- **No AC / task count changes:** 7 REQs / 30 ACs / 24 tasks / 3 PRs unchanged. The advisory resolution is purely wording-clarification on existing AC-022-1 / TRD-016-TASK / AC-022-1-traceability rows.
- **PRD mirror edited:** PRD §4 AC-022-1 already had the terminal set explicit (1.0.3 fix); 1.0.4 updates PRD §3 changelog bullet (line 306) to replace "known-rejected terminal error" with cross-reference to AC-022-1 for the exhaustive terminal set, matching the TRD's wording.

### 1.0.3 — 2026-08-10 (watcher restart-contract pivot)
- **Restart-contract pivot (advisory resolution):** the prior AC-022-1 contract required a "durable offset" that survived VM crash and a "high-water mark captured at EOF on first boot (replay nothing)" behaviour. The new contract is **full replay on every boot + ProjectionStore dedupe + in-memory tail offset with terminal-dispatch advance rule + trailing-line buffer**. The existing AC-022-2 already specified the ProjectionStore dedupe check, so no new ACs or tasks were added — only AC-022-1 was substantively rewritten.
- **§2.2.2 BeadsWatcher description (line 194):** state shape now `%{project_id, jsonl_path, file_handle, read_offset, partial_line}`; `init/1` calls `BeadsWatcher.boot_replay/1` which reads offset 0 → EOF, applies the parse + dedupe + dispatch pipeline, emits `[:watcher, :replay_started]` / `[:watcher, :replay_completed]`, captures EOF as tail-mode `read_offset` start, then schedules `Process.send_after(self(), :read_more, @poll_ms)`. `:read_more` handler: prepends `partial_line` buffer, splits on newlines (carrying partial trailing line across polls), processes each complete line (parse + dedupe + dispatch), advances `read_offset` only after terminal dispatch outcome; transient failures retry with the same deterministic `command_id`.
- **§2.2.4 Technology Choices bullet (line 346):** "High-water mark" bullet replaced with "Boot replay (full-replay-on-every-boot)" bullet explaining the dedupe upper bound + cross-restart safety net trade-off.
- **§2.2.5 Telemetry Taxonomy (line 369):** `[:watcher, :offset_restored]` row removed; replaced with `[:watcher, :replay_started]` and `[:watcher, :replay_completed]` rows.
- **§3 Master Task List (TRD-015-TASK, TRD-016-TASK, TRD-021-TASK):** rewritten to describe the boot replay + dedupe + tail-mode + trailing-line buffer + transient-failure retry contract. TRD-016-TASK now validates AC-022-1, AC-022-2, AC-022-3 (consolidates AC coverage).
- **§5 AC Traceability (AC-022-1 row):** rewritten to assert boot replay + tail-mode offset advance rule + trailing-line buffer.
- **PRD mirror edited:** AC-022-1, risk #3, Appendix B test description, and PRD frontmatter trace updated to match.
- **Counts unchanged:** 7 REQs / 30 ACs / 24 tasks / 3 PRs. TRD frontmatter `total_requirements`, `total_acceptance_criteria`, `total_tasks` are unchanged from 1.0.2.

### 1.0.2 — 2026-08-10 (cascade surgery)

- Cascade surgery: deleted the `TaskBeadLinked` event and the codec dual-registration architecture. The bead-linkage signal rides entirely on `TaskCreated.external_id` (single-event design). REQ-024 ACs reassigned to in-flight cache semantics (AC-024-1..4: cache lookup / cleared-on-terminal / process-local / `command_id`-keyed).
- REQ-025 ACs rotated to match the PRD: AC-025-1 = projection map stores `external_id`; AC-025-2 = `BeadsAdapter.capabilities/0` advertises `:create`; AC-025-3 = behaviour-test callback count 12 with `{:create, 2}` tuple.
- §3 Master Task List rewritten: 24 master tasks across 3 PRs (TRD-001..009 / TRD-010..014 / TRD-015..024). REQ-XXX-N suffixes stripped from the satisfies column.
- §4 Sprint Planning rewritten: 3 sprints aligned to the 3 PRs. Boundary-invariant test (TRD-013) and actor-hook test (TRD-014, 5 scenarios) load-bearing in Sprint 2.
- §5 AC Traceability rewritten: all 30 AC rows map to current task IDs. AC-026's 5 CodeMap rows map to TRD-005/008/009; AC-024's cache ACs map to TRD-010/011/012/014.
- §6 Traceability Validation added: 7 REQs / 30 ACs / 24 master tasks / 3 PRs coverage; 8 architectural invariants enumerated (CommandGateway boundary, in-flight cache, slice invariant preservation, single `ProviderError` factory, per-project gate, `command_id` dedup, orphan janitor close-only-our-orphans, watcher-import branch).
- §7 Next Steps rewritten: 3 PRs only; `foreman doctor task_provider` mentioned as part of PR 3 (TRD-018, TRD-022); docs (TRD-023, TRD-024) ship in PR 3.
- Extended TRD-018 to cover the `foreman doctor task_provider` handler + `BeadsAdapter.recognise_foreman_tag/1` helper; extended TRD-022 to cover `foreman_doctor_test.exs` and the `recognise_foreman_tag/1` unit test.
- Bumped TRD frontmatter: `version: 1.0.0 → 1.0.2`, `total_requirements: 7`, `total_acceptance_criteria: 30`, `total_tasks: 24`, `design_readiness_score: 4.0`, `readiness_score: 4.0`.

### 1.0.1 — 2026-08-10 (failure-contract fix)
- Reframed write-side contract from "atomicity" to "compensating consistency, not true atomicity". The in-process synchronous hook delivers synchronous all-or-nothing for the normal path (`br create` failure returns the provider error and produces no `TaskCreated` event); the orphan janitor absorbs the residual gap from Actor crashes and failed-compensation paths within the configurable grace window.
- Fixed TRD §2.2.2 Error path 1 (was: append `TaskCreated` with `external_id: nil` and surface success with warning — contradicting the PRD; now: return `{:error, %ProviderError{}}` from `do_dispatch/4` without invoking `normalize_to_event_data` or `EventStore.append_to_stream`).
- Updated TRD §2.2.1 Component Boundaries pseudo-code (`{:error, _}` branch now returns the error without appending).
- Added AC-020-5 (failure-as-error contract) — the Actor test asserts `br create` failure returns the error from `do_dispatch/4` without invoking `normalize_to_event_data` or `EventStore.append_to_stream`, emits `[:create, :failure]` telemetry, and produces no `TaskCreated` event / no Foreman task.
- Bumped `total_acceptance_criteria` from 30 → 31 in frontmatter.

### 1.0.0 — 2026-08-10 (initial TRD)
- Initial design specification for the synchronous `task.create` bead-creation slice extending `PRD-2026-48f7b420-foreman-beads-task-provider` and the corresponding PRD `PRD-2026-81315f37-atomic-beads-task-create-and-watcher`. Document ID `TRD-2026-81315f37` is a fresh micro-UUID.
- 8 requirements carried over from the PRD; 31 ACs mapped 1-to-1 to 20 master tasks across 4 PRs (AC count grew from 30 to 31 in the 1.0.1 fix above with the addition of AC-020-5).
- 3 architecture options considered (A: async bridge; B: reconciler; C: synchronous Actor hook — chosen). The chosen architecture is justified by the PRD's compensating-consistency requirement (REQ-020).
- Documentation updates: `docs/user-guide.md`, `docs/cli-reference.md`, `README.md`, `CLAUDE.md` per the `foreman-doc-gate` skill.
