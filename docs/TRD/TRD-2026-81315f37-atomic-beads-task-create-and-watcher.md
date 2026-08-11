---
document_id: TRD-2026-81315f37
label: trd-atomic-beads-task-create-and-watcher
version: 1.0.5
status: Ready for Implementation
date: 2026-08-10
prd_reference: PRD-2026-81315f37
prd_label: prd-atomic-beads-task-create-and-watcher
scale_depth: STANDARD
total_requirements: 7
total_acceptance_criteria: 30
design_readiness_score: 4.0
readiness_score: 4.0
total_tasks: 24
kind: trd
---

# TRD: Atomic Beads Task-Create and JSONL Watcher

## 1. Executive Summary

This TRD specifies the implementation of the design contract in `PRD-2026-81315f37-atomic-beads-task-create-and-watcher`. It is the work that closes the loop between Foreman and Beads in both directions: every `task.create` for a Beads-backed project materialises a Beads issue synchronously inside the Actor hook (Foreman → Beads), and a tail-mode JSONL watcher plus an orphan janitor absorb the opposite direction (Beads → Foreman) and the divergence cases. The contract is **compensating consistency, not true atomicity**: the in-process synchronous hook delivers synchronous all-or-nothing for the normal path (a `br create` failure returns the provider error and produces no `TaskCreated` event), and the orphan janitor absorbs the residual gap from Actor crashes and failed-compensation paths within a configurable grace window — never "no divergence under any failure".

The slice ships as **three PRs** that decompose the work into reviewable, independently deployable chunks:

1. **PR 1 — `TaskProvider` behaviour extension + `BeadsAdapter.create/2`.** Add the `create/2` callback to the behaviour, implement it on `BeadsAdapter`, advertise `:create` in `capabilities/0`, route the `INVALID_TITLE` / `INVALID_PRIORITY` / `INVALID_ISSUE_TYPE` / `DUPLICATE_TASK_ID` / `CREATE_FAILED` error codes through `BeadsAdapter.CodeMap`. Touches the BEHAVIOUR layer — gets the callback count from 11 → 12 and the argv-construction helpers ready.
2. **PR 2 — Actor hook + in-flight cache + watcher-import branch + CommandGateway boundary invariant.** Wires the two-stage aggregate finalization contract (stage 1 validate; stage 2 `BeadsAdapter.create/2` if validation succeeds; stage 3 re-decide with the enriched command payload) into `Aggregate.Actor.do_dispatch/4`; adds the `in_flight_beads: %{command_id => bead_handle}` cache consulted before any `BeadsAdapter.create/2` call; implements the watcher-import branch (skip stage 2 when `payload["external_id"]` is pre-populated); enforces the CommandGateway boundary invariant (`dispatch_operator/2` rejects `task.create` with non-nil `external_id` at the existing envelope allowlist). Touches the COMMAND-DISPATCH layer — the synchronous round-trip is wired; no second event is appended.
3. **PR 3 — Watcher + orphan janitor + opt-in supervision.** Adds `BeadsWatcher` and `BeadsOrphanJanitor` GenServers, the `maybe_*_child/0` helpers in `application.ex`, the `:start_beads_watcher?` / `:start_beads_orphan_janitor?` config flags, and the documentation updates per `foreman-doc-gate`. Touches the SUPERVISION layer — the bi-directional sync is live.

The work is bounded: the synchronous hook reuses `br` version 0.2.19 (already on disk), the Actor hook insertion point is named at `aggregate/actor.ex:156-223`, the projection map extension is a 1-line addition, and the architectural invariants (single `CodeMap` factory, `command_id`-keyed dedup, CommandGateway boundary guard at the envelope allowlist) are already enforced by existing tests.

**Out-of-scope (verbatim from PRD §7):** streaming watcher (FSEvents/inotify), multi-project scan optimisation, `foreman doctor` orphan backlog ranking, interactive orphan conflict resolution, `task.update` operator flows, `foreman bead audit` CLI surface.

---

## 2. Architecture Decision

This section documents the options considered, the chosen architecture, and the rationale for the choice.

### 2.1 Options Considered

#### Option A — Simple async bridge (background handler + polling)
A `task.create` event handler runs OUTSIDE the Actor, subscribed to the event stream via the projection pipeline, and asynchronously calls `br create`. The bead ID becomes available eventually (within a bounded scan window); the linkage would have to be reified through a separate domain event or projection-side merge.

- **Cons:** violates the PRD's compensating-consistency requirement (REQ-020). Operators see a Foreman task whose `external_id` is `nil` for some time, and the design's central commitment — that a `task.create` either materialises a Beads issue together with the Foreman task or fails the create — is undermined. A retry-mid-async-bridge can leave the bead orphaned or the linkage stamped twice.
- **Status:** rejected — synchronous in-process all-or-nothing (with compensating recovery for the residual cases) is the design's central commitment.

#### Option B — Eventual-consistency side channel (separate column + reconciler)
A `task.create` always records `external_id: nil` on the event. A separate reconciler (`BeadsReconciler`) periodically scans unmatched tasks and tries to match them against Beads issues by exact title match. Matched tasks would have to stamp the linkage through a projection-side merge or follow-up command, since this design predates advisory #6's deletion of the dedicated linkage event.
- **Pros:** zero latency on the create path; the reconciler is easy to reason about in isolation.
- **Cons:** title-based matching is fragile (operators rename tasks); the Foreman task can DO WORK before the linkage is established (workflows start; commands run before the bead exists), violating the data-model invariant that `task.create` is the moment of bead birth; the entire PRD's compensating-consistency property is unachievable because the design treats the Foreman task and the Beads issue as independently creatable.
- **Status:** rejected — the reconciler is the wrong abstraction. The PRD requires the bead to exist when the task exists.

#### Option C — Synchronous Actor hook + compensation + janitor (chosen)
The Actor calls `BeadsAdapter.create/2` synchronously inside `do_dispatch/4` between `handle_command/2` returning `{:ok, event_spec}` and `normalize_to_event_data`. The bead ID is merged into the event spec's `external_id`. On append-conflict the Actor compensates by closing the bead. On Actor crash between bead creation and append, the orphan janitor (REQ-023) closes the strander on its grace-window scan. The watcher (REQ-022) closes the reverse direction (Beads → Foreman). All Foreman-originated beads carry `agent_context.foreman` so the watcher and janitor can scope their work.

- **Pros:** compensating consistency for the write path (REQ-020) — synchronous in-process all-or-nothing for the normal path, with the orphan janitor (REQ-023) closing the residual gap from Actor crashes and failed-compensation paths within the configurable grace window; the data-model invariant holds (the bead exists iff the Foreman task exists, except within the grace window); the orphan janitor absorbs the failures of the synchronous hook's presuppositions; the tagging differentiates Foreman-managed from operator-managed beads; the per-project gate keeps non-Beads projects behaviour-equivalent.
- **Cons:** adds `br create` latency to every `task.create` (bounded by PRD-2026-48f7b420 REQ-009 30s default); the Actor hook insertion is the single critical line. (Earlier drafts considered a separate `TaskBeadLinked` event for audit; that design was deleted in advisory #6 because it would have fabricated a domain event outside an aggregate's `handle_command/2`.)
- **Status:** **CHOSEN.** This is the architecture the PRD specifies.

### 2.2 Chosen Architecture

The rest of this section decomposes Option C into its component boundaries, data flow, integration points, technology choices, and telemetry taxonomy.

#### 2.2.1 Component Boundaries

**`ForemanServer.TaskProvider` behaviour** — extended with `create/2` callback.

> `(callback: @callback create(project_id :: String.t(), attrs :: map()) :: {:ok, Issue.t()} | {:error, ProviderError.t()})`

The position of `create/2` in the callback list is between `name/0` and `capabilities/0` (callbacks are returned in declaration order from `behaviour_info(:callbacks)`; placing `create/2` after `name/0` and `capabilities/0` keeps the meta-data callbacks at the front). The total callback count moves from 11 to 12 (AC-026-3).

**`ForemanServer.TaskProviders.BeadsAdapter.create/2`** — implementation of the new callback. Constructs the argv:

```
br create --title <title> --type <task_type> --priority <priority> --description <description>
       --agent-context '{"foreman":{"task_id":"<task_id>","command_id":"<command_id>","origin":"foreman","linked_at":"<iso8601-utc>"}}'
       --db <database_path>
       --json
```

Invokes `BrRunner.run/1` (the `@runner` compile-time resolved module — `BrRunner` in production, `BrRunnerMock` in tests per `config/test.exs:23`). The argv-construction helpers (`scrub_argv/1`, `assign_argv/2`) are reused from the existing `BeadsAdapter`. The `id` returned from `br create --json` is wrapped in `TaskProvider.Issue{id: <id>, ...}` with the remaining fields populated from the JSON envelope.

**`ForemanServer.Aggregate.Actor` (extended)** — holds the state field `in_flight_beads: %{command_id => bead_handle}` in addition to the existing `module_state` / `version` / `aggregate_id` / `aggregate_module`. The `do_dispatch/4` function gains the **two-stage aggregate finalization** sub-step: stage 1 calls `aggregate.handle_command/2` with the original command; if that returns `{:ok, %{} = event_spec}` for `task.create` with `external_id: nil` in the payload, the Actor enters stage 2 (synchronous `br create`) or the watcher-import branch (skip stage 2); stage 3 re-calls `aggregate.handle_command/2` with the enriched payload so the aggregate itself emits the `external_id` field. The actual contract that `do_dispatch/4` consumes from `aggregate.handle_command/2` is `{:ok, event_spec}` where `event_spec` is a single map (NOT a list of typed structs):

```
# stage1: pure aggregate decision on the original command
case aggregate_module.handle_command(state.module_state, original_cmd) do
  {:error, _reason} = err ->
    # Stage 1 rejected (e.g. :task_already_exists, :invalid_priority) — no I/O, no event
    {:reply, err, state}

  {:ok, %{event_type: "TaskCreated", payload: stage1_payload} = event_spec}
  when is_nil(stage1_payload.external_id) ->
    # Stage 1 succeeded for task.create with no pre-supplied external_id.
    # Decide whether to enter stage 2 (Beads I/O) before re-deciding.
    cond do
      # Per-project gate (AC-020-4): the project's provider does not advertise :create
      not :create in provider_capabilities_for(state, original_cmd).supports ->
        # stage1_payload.external_id is nil and no provider create capability →
        # the event emits with external_id: nil, exactly as today.
        proceed_to_normalize_and_append(event_spec)

      # Cache hit (AC-024-1): a prior attempt created the bead; reuse its ID
      cached = Map.get(state.in_flight_beads, original_cmd.command_id) ->
        enriched_payload = Map.put(stage1_payload, :external_id, cached.bead_id)
        # Stage 3: re-decide with enriched payload (deterministic).
        {:ok, enriched_event_spec} =
          aggregate_module.handle_command(state.module_state,
            %{original_cmd | payload: Map.put(original_cmd.payload, :external_id, cached.bead_id)})
        proceed_to_normalize_and_append(enriched_event_spec)

      true ->
        # Stage 2: synchronous br create via the project's configured provider.
        case provider.create(project_id, attrs_with_command_id) do
          {:ok, %TaskProvider.Issue{id: bead_id} = issue} ->
            new_in_flight =
              Map.put(state.in_flight_beads, original_cmd.command_id,
                %{bead_id: bead_id, issue: issue, inserted_at: DateTime.utc_now()})
            state = %{state | in_flight_beads: new_in_flight}

            # Stage 3: re-decide with external_id injected into the command payload.
            # The aggregate emits TaskCreated with external_id: bead_id deterministically.
            enriched_cmd = %{original_cmd | payload: Map.put(original_cmd.payload, :external_id, bead_id)}
            {:ok, enriched_event_spec} =
              aggregate_module.handle_command(state.module_state, enriched_cmd)

            proceed_to_normalize_and_append(state, enriched_event_spec)

          {:error, %TaskProvider.ProviderError{} = err} ->
            # AC-020-5: stage 2 failed → no stage 3, no normalize, no append,
            # no TaskCreated event. Surface err with retryable? for the caller.
            :telemetry.execute(
              [:foreman_server, :task_provider, :beads, :create, :failure],
              %{count: 1}, %{command_id: original_cmd.command_id, code: err.code,
                retryable?: err.retryable?, project_id: project_id})
            {:reply, {:error, err}, state}
        end
    end

  {:ok, %{event_type: "TaskCreated", payload: stage1_payload} = event_spec}
  when not is_nil(stage1_payload.external_id) ->
    # AC-020-6 watcher-import fast path: stage1_payload already carries external_id
    # (mirrored from original_cmd.payload.external_id by Aggregate.get). No stage 2.
    proceed_to_normalize_and_append(event_spec)

  {:ok, %{} = other_event_spec} ->
    # Any other command type (task.update, task.close, etc.) — pass through unchanged.
    proceed_to_normalize_and_append(other_event_spec)

  {:ok, nil} ->
    {:reply, {:ok, nil}, state}
end

# After normalize_to_event_data + EventStore.append_to_stream + receive {:append_ok, ^ref, ...}:
#   on append_ok -> Map.delete(state.in_flight_beads, cmd.command_id) and commit_event/3
# After normalize_to_event_data + EventStore.append_to_stream + receive {:error, ^ref, :wrong_expected_version, ...}:
#   when retries_left > 0:
#     case reload_after_conflict(state) do
#       {:ok, %{state: rehydrated, version: new_version}} ->
#         # AC-020-3 cache hit: REUSE cached external_id by injecting it into cmd BEFORE
#         # the recursive do_dispatch call. do_dispatch then re-decides with the
#         # enriched cmd and retries append with new_version. NO close, NO cache clear.
#         cmd_for_retry = case Map.get(rehydrated.in_flight_beads, cmd.command_id) do
#           nil -> cmd  # cache miss after crash recovery; proceed with fresh stage 2
#           %{bead_id: bead_id} ->
#             %{cmd | payload: Map.put(cmd.payload, :external_id, bead_id)}
#         end
#         do_dispatch(rehydrated, cmd_for_retry, new_version, retries_left - 1)
#       {:error, reason} -> {:reply, {:telemetry, {:error, reason}, %{...}}, state}
#     end
#   when retries_left == 0:
#     # AC-020-3 retry exhausted: compensate (close bead, clear cache, surface error)
#     compensate_and_clear_cache!(cmd)
#     {:reply, {:telemetry, {:error, :wrong_expected_version}, %{...}}, state}
#
# Post-reload re-decision rejection (e.g. :task_already_exists, :phase_terminal):
#   the re-decision returns {:error, _} from handle_command; do_dispatch returns
#   the error WITHOUT re-entering the append loop. compensate_and_clear_cache! runs.
#
# Actor crash: in_flight_beads is process-local state, lost on restart. The replayed
# stream is the source of truth. If the append had succeeded, the bead ID is in the
# persisted event. If it had not, the orphan janitor (REQ-023) handles the strander.
```

**Two-stage contract rationale.** The aggregate remains a pure decision function at every stage — it NEVER performs I/O, never knows about Beads, and never sees `provider.create/2`. The Actor sequences the I/O between two `handle_command/2` invocations: stage 1 validates the unenriched command (this catches `:task_already_exists` and other domain rejections without ever touching the filesystem); stage 3 re-runs the same `handle_command/2` with `:external_id` injected into the command payload, which deterministically produces `event_spec.payload.external_id == bead_id`. The aggregate NEVER sees the bead ID — only the enriched payload's `:external_id`. This preserves the slice invariant ("every emitted event is owned by an aggregate's `handle_command/2`, no module fabricates events") and matches the actual `ForemanServer.Aggregates.Task.handle_command/2` contract: it returns `{:ok, %{stream_id:, event_type:, payload: %{...}}}` (a single event-spec map, NOT a list of typed structs).

**Watcher-import branch rationale.** When the JSONL watcher (REQ-022) reads a new Beads issue, it synthesizes a `task.create` envelope via `CommandGateway.dispatch_system/2` with `external_id: bead.id` already populated in the payload (Beads is the source; the bead is on disk; the Foreman task is the destination). The Actor detects this at stage 1 because `original_cmd.payload.external_id` is set, and because `Aggregate.get(payload, :external_id)` mirrors that into the stage-1 event-spec payload. The second stage-1 clause (`when not is_nil(stage1_payload.external_id)`) catches this and short-circuits straight to `proceed_to_normalize_and_append` — no `br create` is issued, because the bead already exists. This preserves the bead already on disk and avoids creating a duplicate.

**CommandGateway boundary invariant.** `ForemanServer.CommandGateway.dispatch_operator/2` MUST reject `task.create` with non-nil `payload.external_id` at the existing envelope allowlist guard — the check is `get_in(envelope, [:payload, :external_id]) != nil` and the rejection returns `{:error, :external_id_not_allowed_via_operator}`. `dispatch_system/2` is unchanged and remains the trusted path for the watcher-import branch and any future system-issued dispatch that needs to supply a pre-existing `external_id`. The boundary invariant is enforced once at the CommandGateway allowlist; the Actor does NOT perform its own origin check (avoiding redundant enforcement). This invariant prevents operator-issued payloads from bypassing `BeadsAdapter.create/2` by adding an `external_id` to the envelope.

The placement is between the existing `case aggregate_module.handle_command(state.module_state, cmd)` head and the `normalize_to_event_data/2` call. Line numbers are anchored on `packages/foreman_server/lib/foreman_server/aggregate/actor.ex:156-223` (the existing `do_dispatch/4` body). The bounded conflict-recovery loop already exists at `actor.ex:188-207` (the `retries_left > 0` recursion); the new code intercepts the recursive call to inject the cached `external_id` into the `cmd` map before re-deciding.

**`ForemanServer.TaskProviders.BeadsWatcher`** — supervised GenServer. One process per registered project. `@behaviour GenServer`. State: `%{project_id: String.t(), jsonl_path: Path.t(), file_handle: :file.handle(), read_offset: non_neg_integer(), partial_line: binary()}`. **On `init/1`:** resolves the JSONL path via `BrRunner.run(["where", "--db", db_path, "--json"])`, opens the file for reading via `:file.open/2` with `[:read, :binary, :raw]`, calls `BeadsWatcher.boot_replay/1` which reads from offset 0 to current EOF, parses each line, suppresses foreman-tagged beads (AC-022-3 emits `[:watcher, :skipped]`), checks `ProjectionStore` for an existing task with `external_id == bead.id` and skips if already imported (AC-022-2 emits `[:watcher, :reconciled]`), and dispatches a synthetic `task.create` for NEW operator-originated beads (AC-022-2 emits `[:watcher, :imported]`). On replay completion emits `[:watcher, :replay_completed]` with `lines_processed` / `lines_imported` / `lines_suppressed` / `lines_reconciled`. **Boot cursor semantics (3-way cursor priority):** the same single-cursor invariant applies to the boot replay. `BeadsWatcher.boot_replay/1` invokes the same read function with `read_offset = 0`; the function reads from offset 0 to EOF, splits on `\n`, processes complete lines sequentially (terminal dispatch advances `read_offset` past `byte_size(line) + 1`; transient dispatch holds `read_offset` and stops the loop), and on completion sets `read_offset` to the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED — (a) the start byte of the first transient complete-line if the loop stopped at a transient; (b) the start byte of any trailing fragment if the file ends on an unterminated JSONL line; or (c) the file size (EOF) if the file ends on a terminator. `partial_line` is the cached bytes of that first undispatched line (transient-line bytes, trailing-fragment bytes, or `""` respectively). The boot replay therefore preserves partial trailing bytes AND queued lines across the boot→tail-mode transition — when the loop stops at a transient, the cursor HOLDS at the first transient complete-line's start, so queued lines behind the transient are not skipped; a fragment written just before the watcher boots is recognised again on the next poll (the cursor is at the fragment seat or the first transient complete-line seat; the next poll re-reads the fragment plus any newly appended bytes) without a head-of-file rewrite. Schedules the first poll via `Process.send_after(self(), :read_more, @poll_ms)`. **On `:read_more` (single-cursor invariant — 3-way cursor priority):** `read_offset` is the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED — (a) the start byte of the first transient complete-line if the loop stopped at a transient; (b) the start byte of any trailing fragment if the file ends on an unterminated JSONL line; or (c) the file size (EOF) if the file ends on a terminator. `partial_line` is the cached bytes of that first undispatched line (transient-line bytes, trailing-fragment bytes, or `""` respectively); it is kept for observability only and is never required for correctness on the next poll. On every poll: (1) read from `read_offset` to current EOF via `:file.read(file_handle, eof - read_offset)` — the fragment at the seat (if any) is part of the read result and is re-read on transient retries; do NOT prepend `partial_line`; (2) split the bytes on `\n`; (3) process complete lines sequentially in order, stopping at the first transient dispatch; (4) on a terminal dispatch, advance `read_offset` past `byte_size(line) + 1` (the line and its terminator); (5) on a transient dispatch, HOLD `read_offset` and stop the loop (the first transient complete-line is seated at `read_offset` — it is re-read on the next poll, dispatched with the same deterministic `command_id`, and processing continues with any queued lines behind it; if a trailing fragment is also present, it is resolved after the transient-line is terminally dispatched); (6) finally set `partial_line` to the bytes of the FIRST LINE NOT TERMINALLY DISPATCHED — (a) the transient-line bytes from the split if the loop stopped at a transient; (b) the trailing fragment bytes from `last_segment` if the file ends on an unterminated JSONL line; (c) `""` if the file ends on a terminator and the loop processed all lines terminally. `partial_line` is kept for observability only and is never required for correctness on the next poll. The terminal set is the EXHAUSTIVE list defined in the paragraph immediately below — "Terminal vs transient dispatch outcomes" — for the gateway return-shape classifier; the only non-success terminal reasons are the four aggregate domain rejections wrapped by the gateway: `{:error, {:already_exists, :task, _}}`, `{:error, {:invalid_task_status, _}}`, `{:error, {:project_archived, _}}`, `{:error, :project_id_required}`); every other dispatch return is transient and retries with the same deterministic `command_id` (AC-022-2). Reschedules via `Process.send_after(self(), :read_more, @poll_ms)`.
**Terminal vs transient dispatch outcomes (Watcher offset-advance rule).** Every synthetic `task.create` dispatched via `CommandGateway.dispatch_system/2` MUST be classified as either **terminal** (`read_offset` advances to the post-dispatch byte position) or **transient** (`read_offset` is held; the same deterministic `command_id` is retried on the next `:read_more` poll with no head-of-file rewrite). The gateway's return type is `{:ok, map() | nil} | {:error, term()} | {:error, term(), term()}` (per `@type dispatch_result` in `packages/foreman_server/lib/foreman_server/command_gateway.ex:43`); the watcher pattern-matches the FULL gateway return — the outer `{:error, _}` wrapper is part of the classifier, not stripped. The classification is EXHAUSTIVE: a dispatch is terminal iff the gateway returns one of the FIVE wrapped shapes below. Terminal set (all five are wrapped; the inner reason is the aggregate's `handle_command/2` rejection):
1. `{:ok, _}` — successful dispatch; event appended.
2. `{:error, {:already_exists, :task, task_id}}` — rare race; the ProjectionStore dedupe missed but the task already exists (source: `require_absent/2` at `packages/foreman_server/lib/foreman_server/aggregates/task.ex:449-450`).
3. `{:error, {:invalid_task_status, status}}` — defensive; the watcher always sends `"open"` by default, but a status override could trigger this (source: `validate_status/1` at `task.ex:457-470`).
4. `{:error, {:project_archived, project_id}}` — project was archived mid-watch (source: `validate_project_allows_tasks/1` at `task.ex:513-518`).
5. `{:error, :project_id_required}` — defensive; the watcher always carries `project_id` from the registered project (source: `validate_project_allows_tasks/1` at `task.ex:511`).
Every other return shape — `{:error, {:missing_or_invalid, :task_id, _}}`, `{:error, {:wrong_expected_version, _, _}}`, `{:error, term(), term()}` (3-tuple), `{:exit, reason}` from a crashed dispatch, any `ProviderError` shape — is classified **transient**: `read_offset` is held and the same deterministic `command_id` is retried on the next `:read_more` poll. Note: `ProviderError` is NEVER produced by the watcher-import branch because the branch dispatches via `CommandGateway.dispatch_system/2` directly into the aggregate's `handle_command/2` and bypasses `BeadsAdapter.create/2` (the synchronous `br create` hook is skipped per AC-020-6); the synthetic `ProviderError` cases in the transient set are forward-compatibility assertions only — the current implementation cannot emit them. The terminal set is closed: implementers MUST NOT introduce additional terminal atoms without bumping the TRD/PRD; any return value outside the five terminal shapes is transient by construction. This parallels the broader gateway `ProviderError.retryable?` convention without extending it: the only terminal errors in the watcher-import branch are the aggregate's own domain rejections wrapped by the gateway. See AC-022-1 for the offset-advance assertion, AC-022-2 for the dedupe + retry path, and §2.2.6 issue #9 for the slice invariant.

**`ForemanServer.TaskProviders.BeadsOrphanJanitor`** — supervised GenServer. One process per registered project. On `init/1`: logs the boot timestamp and schedules the first scan via `Process.send_after(self(), :scan, @grace_ms)` (the grace window covers the FOREMAN side's worst-case `br create` + append latency; first scan on grace-window expiry, not on boot). On `:scan`: reads the JSONL, filters for `agent_context.foreman`, checks each against `ProjectionStore` for the corresponding task's existence and status, and closes orphans via `BeadsAdapter.complete/3` with the deterministic transition-comments per AC-023-2 / AC-023-3. Reschedules on `@scan_interval_ms`.

**`ForemanServer.Application` (extended)** — two new `maybe_*_child/0` helpers:

- `maybe_beads_watcher_child/0` — returns `Supervisor.child_spec(...)` if `:start_beads_watcher?` is `true`, else `[]`.
- `maybe_beads_orphan_janitor_child/0` — returns `Supervisor.child_spec(...)` if `:start_beads_orphan_janitor?` is `true`, else `[]`.

Mirrors the existing `maybe_json_schema_cache_child/0` and `maybe_project_provider_projector_child/0` pattern at `application.ex:114-132`.

**`ForemanServer.ProjectionStore` (extended)** — `TaskCreated` handler stores `external_id` on the task map (currently absent per PRD §2.1 evidence). NO new event handler — the bead-linkage signal rides entirely on the existing `TaskCreated.external_id` field; idempotency is provided by the aggregate's stream-version semantics, not by a separate handler.

#### 2.2.2 Data Flow

**Happy path (write-side, `task.create` for Beads-backed project):**

```
1.  Operator: foreman task create --project-id <p> --title <t> --description <d> --priority <p> --task-type <ty>
2.  Go CLI: POST /api/commands {command_id: <uuid>, command_type: "task.create", payload: {project_id, title, description, priority, task_type}, envelope: {actor: "operator", timestamp: <iso8601>}}
3.  Phoenix: CommandGateway.dispatch_operator/2 — allowed (task.create is in allowlist; payload.external_id MUST be nil or dispatch returns {:error, :external_id_not_allowed_via_operator})
4.  CommandRouter.dispatch(command)
5.  Aggregator.start_aggregate(Task, project_id:<prj>:<task_id>) — starts Actor if not running
6.  Actor.handle_call({:command, cmd}, ...)
7.  Actor.do_dispatch(state, cmd, expected_version, retries_left)
8.  STAGE 1: aggregate_module.handle_command(state.module_state, cmd) returns {:ok, %{event_type: "TaskCreated", payload: %{...external_id: nil...}}}
9.  Watcher-import fast path (AC-020-6): if cmd.payload.external_id is set, stage1_payload.external_id is also set (mirrored by Aggregate.get) — short-circuit directly to step 13. NO br create is issued.
10. Per-project gate (AC-020-4): if :create not in capabilities.supports, proceed directly to step 13. event_spec.payload.external_id remains nil.
11. In-flight cache lookup (AC-024-1): if Map.get(state.in_flight_beads, cmd.command_id) hits, REUSE cached bead_id; STAGE 3 enriches cmd.payload.external_id = cached.bead_id; jump to step 13.
12. STAGE 2: BeadsAdapter.create/2 (BrRunner.run(["create", "--title", title, "--type", task_type, "--priority", priority, "--description", description, "--agent-context", '<json>', "--db", db_path, "--json"]))
    - On {:ok, %TaskProvider.Issue{id: "foreman-abc", ...}}: state.in_flight_beads[command_id] = %{bead_id: "foreman-abc", issue: <issue>, inserted_at: <iso8601>}
    - STAGE 3: re-decide aggregate_module.handle_command(state, %{cmd | payload: Map.put(cmd.payload, :external_id, "foreman-abc")}) → returns {:ok, %{event_type: "TaskCreated", payload: %{...external_id: "foreman-abc"...}}}
    - On {:error, %TaskProvider.ProviderError{code: "INVALID_TITLE", retryable?: false}}: see Error Path 1 below.
13. normalize_to_event_data(event_spec, event_id)
14. CommandRouter {:append, aggregate_id, [event_data], expected_version, ref, self()}
15. Receive {:append_ok, ^ref, count, append_latency_ms}:
    - state.module_state = aggregate_module.apply_event(state.module_state, event_data)
    - state.version = expected_version + 1
    - Map.delete(state.in_flight_beads, cmd.command_id) (terminal cache cleanup)
    - commit_event(state, event_spec, append_latency_ms)
16. Actor returns {:ok, event_spec} to caller
17. Phoenix responds 200 OK to Go CLI
18. Go CLI prints task_id and bead_id (if JSON output)
```

**Error path 1 — `br create` fails (write-side):**

```
12. BeadsAdapter.create/2 returns {:error, %ProviderError{code: "INVALID_TITLE", retryable?: false}}
    - The Actor returns {:error, %ProviderError{}} from do_dispatch/4 directly to the caller
    - NO call to normalize_to_event_data
    - NO EventStore.append_to_stream — no TaskCreated event is emitted
    - NO Foreman task is created — the operator's `foreman task create` call fails with the provider error in the response body
    - state.in_flight_beads[command_id] is NOT populated (no bead_handle to track; no bead was actually created)
    - NO Foreman task exists, so there is no second-event linkage to skip — the single TaskCreated event is simply not emitted
    - Emit [:foreman_server, :task_provider, :beads, :create, :failure] with command_id, code, retryable?, the proposal task_id, project_id
    - The orchestration layer (CommandRouter / Phoenix) decides whether to retry; the `retryable?` flag from the CodeMap row is the signal:
      - retryable?: false (INVALID_TITLE, INVALID_PRIORITY, INVALID_ISSUE_TYPE, DUPLICATE_TASK_ID) → surface the error to the operator; the operator sees the failure and decides whether to retry with different inputs
      - retryable?: true (CREATE_FAILED, transient subprocess failures) → the orchestration layer reissues the command; on retry state.in_flight_beads[command_id] is empty (no entry was created) so the synchronous hook re-attempts br create
```

This is the **synchronous all-or-nothing guarantee for the in-process path**: when `BeadsAdapter.create/2` returns `{:ok, _}`, the Actor proceeds with append; when it returns `{:error, %ProviderError{}}`, the Actor returns the error WITHOUT appending — NO `TaskCreated` event is emitted, NO Foreman task exists, and the operator sees the create fail with the provider error.

The two failure paths that escape this in-process guarantee — (a) Actor crash between `br create` returning success and the `EventStore.append_to_stream` confirmation, and (b) `br close` compensation failure on an append-conflict — explicitly leave an orphan bead on disk in Beads with no Foreman task until the orphan janitor (REQ-023) recovers it on its grace-window scan. The cross-store contract is therefore **compensating consistency, not true atomicity**: the design's promise is "no eventual divergence within the configurable grace window", not "no divergence under any failure".

**Error path 2 — append-conflict (write-side, after `br create` succeeded):**


```
13. EventStore.append_to_stream returns {:error, :wrong_expected_version}
14. [PRD ADD] Bounded retry path (AC-020-3, AC-024-1) — cache-aware:
    - CONSULT state.in_flight_beads[command_id] FIRST before any close or re-create:
      - Cache HIT (a previous attempt already created the bead):
        - REUSE cached bead_id; do NOT call br close; do NOT clear cache
        - reload_after_conflict(state) → rehydrate state + new_version
        - INJECT cached bead_id into cmd: %{cmd | payload: Map.put(cmd.payload, :external_id, cached.bead_id)}
        - Recursive do_dispatch(rehydrated_state, enriched_cmd, new_version, retries_left - 1)
        - If the re-decision rejects ({:error, :phase_terminal} or {:error, :task_already_exists, _}):
            → compensate (BeadsAdapter.complete with transition_comment "foreman-compensation:re-decision-rejected")
            → Map.delete(state.in_flight_beads, command_id)
            → surface {:error, _} to caller; do NOT re-enter the append loop
        - If retries_left == 0 (cache hit + retry exhaustion):
            → compensate (BeadsAdapter.complete with transition_comment "foreman-compensation:append-conflict-retry-exhausted")
            → Map.delete(state.in_flight_beads, command_id)
            → surface {:telemetry, {:error, :wrong_expected_version}, ...} to caller
      - Cache MISS (e.g. the previous attempt crashed and lost in_flight_beads, OR this is a brand-new conflict with no cached bead):
        - reload_after_conflict(state) → rehydrate state + new_version
        - Recursive do_dispatch(rehydrated_state, cmd, new_version, retries_left - 1)
        - On the next dispatch the cond branches re-evaluate; if cmd.payload.external_id is still nil, stage 2 (br create) runs again — a NEW bead is created and the cache is repopulated
        - On retries_left == 0: surface {:telemetry, {:error, :wrong_expected_version}, ...}; no compensation (nothing to close)
15. CLOSE-ONLY-ONCE: every BeadsAdapter.complete call MUST consult state.in_flight_beads[command_id] FIRST. Once an entry is removed, subsequent retries MUST NOT call close on the same logical command (defeats REQ-024's one-br-create-per-command_id invariant).
16. Telemetry:
    - On cache-hit + retry exhausted close: [:foreman_server, :task_provider, :beads, :create, :compensated] with command_id, bead_id, compensation_reason: :retry_exhausted
    - On cache-hit + re-decision rejected close: [:foreman_server, :task_provider, :beads, :create, :compensated] with command_id, bead_id, compensation_reason: :re_decision_rejected
    - On close failure: [:foreman_server, :task_provider, :beads, :create, :compensate_failure] with command_id, bead_id, close_error
    - Orphan janitor (REQ-023) absorbs residual compensation failures on grace-window scan
```
**Read-side path (Beads → Foreman, watcher):**

```
1. Operator: echo "Manual note" | br create --title "Manual note" --db .beads/beads.db --json
2. Beads appends the issue to .beads/issues.jsonl
3. BeadsWatcher reads the new line
4. Parses the JSONL entry; checks agent_context.foreman — absent
5. Get-or-create the Foreman task on the corresponding project (via ProjectionStore lookup by external_id, then by title)
6. Synthesizes a command envelope: {command_id: <new uuid>, command_type: "task.create", payload: {project_id, title, description, priority, task_type, external_id: bead_id}, envelope: {actor: "system:beads-watcher", timestamp: <iso8601>}}
7. CommandGateway.dispatch_system/2 (system origin, no allowlist check)
8. CommandRouter.dispatch(command)
9. Aggregator.start_aggregate(Task, ...) — starts Actor
10. Actor enters do_dispatch/4
11. [PRD ADD] Check cmd.payload.external_id: present → skip br create (the bead is the source, Beads already has it)
12. The event_spec proceeds to normalize_to_event_data with external_id: bead_id (the bead's ID is already in the payload)
13. EventStore.append_to_stream succeeds
14. ProjectionStore writes task map with external_id: bead_id
```

**Cleanup path (orphan janitor, post-grace-window):**

```
1. BeadsOrphanJanitor scans .beads/issues.jsonl
2. Filter: agent_context.foreman present (Foreman-originated)
3. For each match, check ProjectionStore for corresponding task:
   - (a) No task exists → call BeadsAdapter.complete with transition_comment: "foreman-orphan:no-task"
   - (b) Task exists but is closed/failed → call BeadsAdapter.complete with transition_comment: "foreman-orphan:terminal-task"
   - (c) Task exists and is in active state → skip (not an orphan)
4. Emit telemetry events per the matrix in §2.2.5
```

#### 2.2.3 Integration Points

| Integration | Direction | Trigger | Surface |
|---|---|---|---|
| Go CLI → Phoenix | inbound | every command | `POST /api/commands` (existing; no change) |
| Phoenix → CommandGateway | inbound | every command | `dispatch_operator/2` (existing; extended with `external_id` guard at AC-020-7) / `dispatch_system/2` (existing; trusted path for the watcher) |
| CommandGateway → CommandRouter | outbound | every command | `dispatch/1` (existing; no change) |
| CommandRouter → Aggregator | outbound | every command | `start_aggregate/2` (existing) |
| Aggregator → Actor | outbound | every command | `GenServer.call/3` (existing) |
| Actor → BeadsAdapter (NEW) | outbound | only for `task.create` on Beads-backed projects, when `cmd.payload.external_id` is `nil` | `BeadsAdapter.create/2` (extended) |
| BeadsAdapter → BrRunner | outbound | every `br` invocation | `BrRunner.run/1` (existing; `@runner` resolved at compile time) |
| BrRunner → `br` subprocess | outbound | every `br` invocation | `System.cmd/3` (existing; SIGTERM-then-SIGKILL per PRD-2026-48f7b420 REQ-009-2) |
| ProjectionStore → Read API | outbound | every event | `apply_event_by_type/3` (extended to read `payload.external_id` for `TaskCreated`; no new event handler) |
| Read API → Go CLI | outbound | every read | `GET /api/tasks/:id` (existing; `external_id` returned in JSON when present) |
| BeadsWatcher → CommandGateway | outbound | every new JSONL line | `dispatch_system/2` of `task.create` with `external_id` pre-populated (NEW) |
| BeadsOrphanJanitor → BeadsAdapter | outbound | every orphan match | `BeadsAdapter.complete/3` (existing) |
| BeadsOrphanJanitor → ProjectionStore | outbound | every scan | `get_task/2` and `all_tasks/1` (existing) |
| BeadsWatcher → BeadsAdapter | outbound | at boot for `br where` | `BrRunner.run(["where", "--db", db_path, "--json"])` (NEW) |
| Actor → in-flight cache (NEW, process-local state) | outbound | every `task.create` decision | `Map.put/Map.delete` on `state.in_flight_beads` (no I/O; consulted before any `br create` and cleared on terminal success or compensation) |

#### 2.2.4 Technology Choices

- **JSONL tail mode:** `:file.open/2` + read-until-EOF + `Process.send_after(self(), :read_more, @poll_ms)` polling. The 2s poll interval is the trade-off between latency and resource usage; the PRD allows override via `:beads_watcher_poll_ms`. Streaming via `:file_system` (FSEvents on macOS, inotify on Linux) is intentionally deferred (see PRD §7 "out-of-scope gaps" #1).
- **JSONL parsing:** `Jason.decode!/1` per line. The JSONL format is one JSON object per line; line-delimited, no nested arrays. Each line is parsed independently.
- **Boot replay (full-replay-on-every-boot):** every watcher's `init/1` reads the JSONL from offset 0 to current EOF, applying the same parse + dedupe + dispatch pipeline as tail mode. Replay is bounded by `lines_processed * (read + parse + ProjectionStore lookup)`; already-imported beads are no-op via AC-022-2 dedupe so the steady-state cost is bounded. After replay, the watcher captures the current EOF as the tail-mode `read_offset` start and enters tail mode. **No durable offset store is required**: the `ProjectionStore` dedupe is the cross-restart safety net (AC-022-2), and the orphan janitor (REQ-023) absorbs any foreman-tagged residual. The trade-off is O(N) boot work per restart vs. correctness across VM crash; this is intentionally accepted because the JSONL is bounded by bead volume and the replay is mostly no-op dedupe hits once steady-state is reached.
- **Supervisor strategy:** `rest_for_one` is the natural choice for the watcher / janitor pair — if the registry is restarted, both children must restart. The existing `ForemanServer.TaskProvider.Supervisor` (or equivalent) is the parent supervisor; the new children are added to its child list.
- **Single-event design rationale:** the bead-linkage signal rides entirely on the existing `TaskCreated.external_id` field; no `TaskBeadLinked` event exists, no second append happens, and no codec dual-registration is required. The slice invariant ("every domain event is emitted by an aggregate's `handle_command/2` routed through `CommandRouter` — no module emits events directly") is preserved because the Actor enriches the COMMAND payload (not the event spec) and re-invokes `handle_command/2` so the aggregate itself emits the enriched event.
- **Two-stage finalization rationale:** the Actor sequences the I/O between two `handle_command/2` invocations so the aggregate stays a pure decision function at every stage. Stage 1 validates the unenriched command (catches `:task_already_exists` and other domain rejections without filesystem I/O); stage 2 calls `BeadsAdapter.create/2`; stage 3 re-runs `handle_command/2` with `:external_id` injected into the command payload so the aggregate emits `event_spec.payload.external_id == bead_id` deterministically. The aggregate NEVER sees the bead ID — only the enriched payload's `:external_id` field.
- **Watcher-import branch rationale:** the JSONL watcher synthesizes a `task.create` envelope via `CommandGateway.dispatch_system/2` with `external_id` already populated (Beads is the source; the bead is on disk). The Actor detects this at stage 1 because `Aggregate.get(payload, :external_id)` mirrors the value into the stage-1 event-spec payload; the second stage-1 clause (`when not is_nil(stage1_payload.external_id)`) short-circuits straight to normalization-and-append. No `br create` is issued, preserving the bead already on disk.
- **CommandGateway boundary invariant rationale:** `dispatch_operator/2` rejects `task.create` with non-nil `payload.external_id` at the existing envelope allowlist guard (returns `{:error, :external_id_not_allowed_via_operator}`); `dispatch_system/2` is unchanged. The boundary invariant is enforced once at the CommandGateway allowlist; the Actor does NOT perform its own origin check. This prevents operator-issued payloads from bypassing `BeadsAdapter.create/2` by adding `external_id` to operator envelopes.
- **Command dedup:** CommandRouter's existing `command_id`-keyed dedup applies to the SINGLE append — a retry by the same operator reuses the same `command_id` and is dropped before reaching the Actor. The `in_flight_beads` cache key is the FIRST command's `command_id`; the cache survives the conflict-recovery recursion because it lives on `state.in_flight_beads` (process-local, NOT request-local).
- **CodeMap factory:** all `ProviderError` constructions continue through `BeadsAdapter.CodeMap.map_error/2`. The 5 new rows reuse the existing helper functions for `retryable?` propagation and context-marshal.

#### 2.2.5 Telemetry Taxonomy

All events emitted under `[:foreman_server, :task_provider, :beads, ...]` (consistent with the existing `[:foreman_server, :task_provider, ...]` taxonomy from PRD-2026-48f7b420):

| Event | Direction | Trigger | Metadata |
|---|---|---|---|
| `[:create, :success]` | outbound | `br create` succeeds; bead ID is on disk | `command_id`, `bead_id`, `task_id`, `project_id`, `?duration_ms` (always) |
| `[:create, :failure]` | outbound | `br create` fails (any CodeMap row) | `command_id`, `?bead_id` (nil on failure), `code`, `retryable?`, `task_id`, `project_id` |
| `[:create, :compensated]` | outbound | append-conflict triggers compensation; br close succeeds | `command_id`, `bead_id`, `task_id`, `project_id`, `?duration_ms` |
| `[:create, :compensate_failure]` | outbound | append-conflict triggers compensation; br close fails | `command_id`, `bead_id`, `task_id`, `project_id`, `close_code` |
| `[:create, :command_id_mismatch]` | outbound | orphan janitor finds a foreman-tagged bead whose `command_id` does not match any Foreman command (suspected tag spoofing) | `bead_id`, `spoofed_command_id`, `?duration_ms` |
| `[:watcher, :imported]` | outbound | watcher reads a new non-Foreman bead and synthesizes a `task.create` envelope | `bead_id`, `task_id`, `project_id`, `?duration_ms` |
| `[:watcher, :skipped]` | outbound | watcher reads a new foreman-tagged bead (suppression) | `bead_id`, `project_id` |
| `[:watcher, :reconciled]` | outbound | watcher reads a new bead that already has a Foreman task (no-op) | `bead_id`, `task_id`, `project_id` |
| `[:watcher, :replay_started]` | outbound | watcher boot — full replay begins (offset 0 → EOF) | `project_id`, `bytes_to_process` |
| `[:watcher, :replay_completed]` | outbound | watcher boot replay finished | `project_id`, `lines_processed`, `lines_imported`, `lines_suppressed`, `lines_reconciled`, `?duration_ms` |
| `[:orphan, :janitor, :closed]` | outbound | janitor closes a foreman-tagged orphan | `bead_id`, `?task_id`, `project_id`, `reason` ("no-task" or "terminal-task"), `?duration_ms` |
| `[:orphan, :janitor, :retained]` | outbound | janitor inspects a non-foreman-tagged bead (skipped) | `bead_id`, `project_id` |
| `[:orphan, :janitor, :grace_expired]` | outbound | janitor scans but the grace window has not yet elapsed for a particular bead | `bead_id`, `linked_at_age_ms`, `grace_ms` |

Telemetry handler: the existing `[:foreman_server, :task_provider, :beads, :create, :success|:failure|:compensated]` handler at `config/runtime.exs` (or equivalent) is extended with the new events; the handler dispatches to operational dashboards in the same style as the existing telemetry.

#### 2.2.6 Reused Capabilities

- **`ForemanServer.CommandGateway.dispatch_operator/2`** — operator envelope routing; allowlist filter (already enforced for `task.create`); extended at the allowlist guard to reject non-nil `payload.external_id` (AC-020-7) with `{:error, :external_id_not_allowed_via_operator}`.
- **`ForemanServer.CommandGateway.dispatch_system/2`** — system envelope routing; no allowlist filter; the trusted path for the watcher (REQ-022) and any future system-issued dispatch that needs to pre-populate `external_id`. Unchanged.
- **`ForemanServer.CommandRouter.dispatch/1`** — `command_id`-keyed dedup (applied to the single append only).

- **`ForemanServer.Aggregate.Actor.do_dispatch/4`** — command dispatch and append-confirmation loop (extended in-place with the two-stage finalization hook at lines 156-223).
- **`ForemanServer.Aggregate.Actor.reload_after_conflict/1`** — append-conflict recovery (reused for the single append; the in-flight cache survives the recursion).
- **`ForemanServer.TaskProvider.Registry.route/2`** — per-project provider resolution (already supports routing on a method-name; the `:create` route is added with the same shape as `:claim`).
- **`ForemanServer.TaskProviders.BeadsAdapter.capabilities/0`** — extended with `:create` (one entry added).
- **`ForemanServer.TaskProviders.BeadsAdapter.CodeMap.map_error/2`** — factory for `ProviderError` (5 new rows added).
- **`ForemanServer.ProjectionStore.apply_event_by_type/3`** — projection handler (extended to read `event_spec.payload.external_id` for `TaskCreated`; no new event handler).
- **`ForemanServer.TaskProvider.Issue`** — wraps the `br create --json` output (existing 12-field struct; the optional fields are populated as the JSON envelope carries them).
- **`BrRunner.run/1`** — `br` subprocess layer (existing; `@runner` resolved at compile time; `BrRunnerMock` in tests).
- **`ForemanServer.Application.maybe_*_child/0` pattern** — opt-in supervisor child pattern (existing; mirrored for the watcher and janitor).

Issues that explicitly land inside the slice:

1. **Existing `command_id` dedup covers the new path.** `CommandRouter` dedupes on `command_id`; retries by the same operator reuse the same `command_id` and are dropped before reaching the Actor. The `in_flight_beads` cache key is the FIRST command's `command_id`; the cache survives the conflict-recovery recursion because it lives on `state.in_flight_beads` (process-local, NOT request-local). There is exactly ONE append per logical command.

2. **The synchronous hook REPLACES no existing aggregate behaviour.** The `task.create` handler in `packages/foreman_server/lib/foreman_server/aggregates/task.ex:163-195` already extracts `external_id` from the payload via `Aggregate.get(payload, :external_id)` (the field has been optional but unused for years). The handler does not need to change. The Actor hook is the only path that supplies the new `external_id` value; the aggregate emits the enriched `event_spec` on the second `handle_command/2` invocation.

3. **The `in_flight_beads` cache is process-local and NOT replicated across Actor restarts.** The cache is a process state field, not a GenServer-managed state. On crash, the cache is rehydrated from nothing (and the orphan janitor absorbs the strander). This is the simpler design and avoids the dual-writer problem (state vs CommandRouter dedup).

4. **The orchestrator's `BeadsAdapter` is the ONLY module that constructs `br` subprocess argv.** Per the PRD-2026-48f7b420 architectural invariant (REQ-008-5a), all `ProviderError` constructions pass through `BeadsAdapter.CodeMap`. The synchronous hook does NOT introduce a new error-construction path. The architecture test (`test/foreman_server/task_providers/provider_error_factory_test.exs`) walks the codebase and asserts that every `%ProviderError{...}` struct literal lives inside `BeadsAdapter.CodeMap`.

5. **The `external_id` field addition to the `TaskCreated` projection map is BACKWARDS-compatible.** Existing `TaskCreated` events in the event store do not carry `external_id`; the projection handler reads `event_spec.payload.external_id` (default `nil` via `Map.get(payload, :external_id)` semantics) and writes the field. Foreman's read API returns `external_id: nil` for legacy tasks; for new tasks, it returns the bead ID. The change is additive; no codec re-registration is required because `external_id` was already an optional field on `Events.TaskCreated`.

6. **CommandGateway boundary invariant (architectural).** `dispatch_operator/2` MUST reject `task.create` envelopes with non-nil `payload.external_id` at the existing envelope allowlist guard. `dispatch_system/2` is unchanged and remains the trusted path for the watcher-import branch. The invariant is enforced ONCE at the CommandGateway boundary; the Actor does not duplicate the origin check. Adding a new dispatch path (or a new operator type) requires re-validating the boundary invariant; this is the architectural invariant that prevents operator-side payload forgery from skipping `BeadsAdapter.create/2`.

7. **Watcher terminal-vs-transient dispatch classification is EXHAUSTIVE (architectural).** The watcher-import branch in `BeadsWatcher` dispatches synthetic `task.create` commands via `CommandGateway.dispatch_system/2` (the trusted system path, NOT through `BeadsAdapter.create/2`, per AC-020-6). The classification of every gateway return value as **terminal** (advance `read_offset`) or **transient** (hold `read_offset`; retry on next poll with same deterministic `command_id`) MUST be exhaustive and is defined in §2.2.2 paragraph "Terminal vs transient dispatch outcomes" — there is no third outcome. **Terminal set (exhaustive, wrapped shapes):** `{:ok, _}`; `{:error, {:already_exists, :task, _}}`; `{:error, {:invalid_task_status, _}}`; `{:error, {:project_archived, _}}`; `{:error, :project_id_required}`. Every other gateway return is transient (including `ProviderError{retryable?: true}`, `:wrong_expected_version` bubbling past actor retry, subprocess timeouts, DB locks, `{:exit, :killed}`). The classifier pattern-matches the FULL gateway return shape (outer `{:error, _}` wrapper preserved, inner reason matched by arity-distinct patterns). Critically, `ProviderError` is NEVER produced by this branch because the branch bypasses `BeadsAdapter.create/2` — the synthetic `ProviderError{retryable?: true}` transient test is forward-compatibility scaffolding only, ensuring the classifier rejects it correctly if any future refactor routes the watcher through `BeadsAdapter`.

---

## 3. Master Task List (PR-by-PR)

The work is shipped as **3 PRs** with **24 atomic tasks** (rows prefixed with task IDs). AC traceability is encoded in the `satisfies` and `validates` columns. Each PR has a `**Shippable State:**` line that names the integration point that PR makes runnable.

### PR 1 — `TaskProvider` behaviour extension + `BeadsAdapter.create/2`

**Shippable State:** `BeadsAdapter.create/2` is runnable end-to-end with mocked `BrRunner`; an Actor invocation that exercises the path will get the bead ID from the mocked subprocess without yet wiring the synchronous hook (the synchronous hook lands in PR 2).

| id | task | est. | deps | satisfies | validates |
|---|---|---|---|---|---|
| TRD-001-TASK | Extend `ForemanServer.TaskProvider` behaviour with `@callback create/2` declaration (between `name/0` and `capabilities/0`); add `create/2` to the `@doc` summary | S | — | REQ-025 | AC-025-3 |
| TRD-002-TASK | Update `task_provider_test.exs`: `length(callbacks) == 12` at lines 12 AND 24; add `assert {:create, 2} in callbacks` after the existing `add_dependency` assertion; extend the capabilities assertion to verify `:create` is in `BeadsAdapter.capabilities().supports` | S | TRD-001-TASK | REQ-025 | AC-025-2, AC-025-3 |
| TRD-003-TASK | Implement `BeadsAdapter.create/2` — construct argv (with `--agent-context` JSON containing the four tag fields: `foreman.task_id`, `foreman.command_id`, `foreman.origin` = `"foreman"`, `foreman.linked_at` ISO8601 UTC), call `BrRunner.run/1`, parse the JSON output, wrap into `TaskProvider.Issue{}` | M | TRD-001-TASK | REQ-020, REQ-021 | AC-020-1, AC-021-1, AC-021-3 |
| TRD-004-TASK | Add `BR_TIMEOUT_SUBPROCESS` mapping usage in `create/2` for the per-call timeout (reuses the existing 30s default from PRD-2026-48f7b420 REQ-009-2); add `preflight_database/2` re-validate plus the existing `BrRunner.run/1` (no new pattern) | S | TRD-003-TASK | REQ-020 | AC-020-1 |
| TRD-005-TASK | Add 5 new CodeMap rows: `INVALID_TITLE`, `INVALID_PRIORITY`, `INVALID_ISSUE_TYPE`, `DUPLICATE_TASK_ID`, `CREATE_FAILED` (fallback); each row sets `retryable?` per AC-026-1 through AC-026-5; all 5 reuse the existing 8-key allowlist (no new context keys) | S | TRD-003-TASK | REQ-026 | AC-026-1, AC-026-2, AC-026-3, AC-026-4, AC-026-5 |
| TRD-006-TASK | Extend `BeadsAdapter.capabilities/0` to include `:create` in `supports` (now `[:claim, :close, :reopen, :annotate, :set_priority, :set_assignee, :list_dependencies, :add_dependency, :remove_dependency, :create]`) | XS | TRD-001-TASK | REQ-025 | AC-025-2 |
| TRD-007-TASK | Update `TaskProvider.Registry.route/2` (line 69) to dispatch `:create` to the same per-project state; update `register_for_project/3` (line 89) if the routing shape needs adjustment (likely no change) | S | TRD-001-TASK, TRD-003-TASK | REQ-020 | AC-020-4 |
| TRD-008-TASK | Pre-emptive Foreman-side validation in `BeadsAdapter.create/2`: reject out-of-range priority (must be 0..P4) and out-of-enum task_type before constructing argv; this prevents the CodeMap's `INVALID_PRIORITY` / `INVALID_ISSUE_TYPE` rows from firing on inputs the system could have rejected earlier | S | TRD-003-TASK | REQ-026 | AC-026-2, AC-026-3 |
| TRD-009-TASK | Write `BeadsAdapter.create/2` test suite — happy path (mock `BrRunner` returns `{:ok, JSON}`); `INVALID_TITLE` path (mock returns VALIDATION envelope); `INVALID_PRIORITY` path; `INVALID_ISSUE_TYPE` path; `DUPLICATE_TASK_ID` path; `CREATE_FAILED` fallback path; the `agent_context` JSON-shape assertion (all 4 fields present, `origin` literal `"foreman"`, `linked_at` ISO8601 UTC) | M | TRD-003-TASK, TRD-005-TASK, TRD-008-TASK | REQ-020, REQ-021, REQ-026 | AC-020-1, AC-021-1, AC-026-1, AC-026-2, AC-026-3, AC-026-4, AC-026-5 |

**PR 1 shippable:** `BeadsAdapter.create/2` is runnable from REPL with a mocked `BrRunner`. The synchronous hook is not yet wired; the Actor still produces a `TaskCreated` event with `external_id: nil`.

### PR 2 — Actor hook + in-flight cache + watcher-import branch + boundary invariant

**Shippable State:** The synchronous two-stage finalization hook is wired into `do_dispatch/4` end-to-end. Issuing a `task.create` for a Beads-backed project produces a `TaskCreated` event with `external_id` populated via the second `handle_command/2` invocation. The watcher and janitor are not yet active (lands in PR 3).

| id | task | est. | deps | satisfies | validates |
|---|---|---|---|---|---|
| TRD-010-TASK | Extend `ForemanServer.Aggregate.Actor` state with `in_flight_beads: %{command_id => bead_handle}` field (default `%{}` in `init/1`); the field is part of the state struct, not a GenServer-managed state | S | — | REQ-024 | AC-024-1, AC-024-2, AC-024-3, AC-024-4 |
| TRD-011-TASK | Insert two-stage finalization hook in `do_dispatch/4` (between `aggregate.handle_command/2` returning `{:ok, event_spec}` and `normalize_to_event_data`): (stage 1) call `aggregate.handle_command/2` with the original command; if `stage1_payload.external_id` is `nil` and `original_cmd.payload.external_id` is `nil`, proceed to stage 2; if non-nil, watcher-import branch — proceed directly to stage 5 (normalize-and-append). (stage 2) per-project gate via `provider_capabilities_for(state, original_cmd).supports` membership — if `:create` not in supports, proceed to stage 5 with `event_spec.payload.external_id == nil`. (stage 3) in-flight cache lookup — if `Map.get(state.in_flight_beads, cmd.command_id)` hits, REUSE cached bead ID and jump to stage…
| TRD-012-TASK | Append-conflict compensation: on `:wrong_expected_version` after `br create` has populated the cache, the recursive `do_dispatch` reloads state and re-decides with the cached `bead_id`. On retry exhaustion (`@max_conflict_retries` reached) OR on re-decision rejection (`{:error, _}` from `handle_command/2`), close the bead via `BeadsAdapter.complete/3` with `transition_comment: "foreman-compensation:append-conflict-retry-exhausted"` (or `"…re-decision-rejected"` respectively), emit `[:foreman_server, :task_provider, :beads, :create, :compensated]`, clear the cache entry, return the error from `do_dispatch/4`. CLOSE-ONLY-ONCE: `in_flight_beads[command_id]` consulted before any close; once cleared, no subsequent close for the same logical comma…
| TRD-013-TASK | CommandGateway boundary invariant: extend `ForemanServer.CommandGateway.dispatch_operator/2` (existing envelope allowlist guard at `command_gateway.ex`) to reject `task.create` envelopes with non-nil `payload.external_id` — return `{:error, :external_id_not_allowed_via_operator}`. `dispatch_system/2` is unchanged and remains the trusted path for the watcher. The Actor does NOT duplicate this check | S | TRD-011-TASK | REQ-020 | AC-020-7 |
| TRD-014-TASK | Write `actor_hook_test.exs` — happy path (mock `BrRunner` returns bead ID; verify `event_spec.payload.external_id == bead_id` in the normalized event data); append-conflict path (mock append returns `wrong_expected_version`; verify compensation closes the bead; verify `in_flight_beads` is cleared after compensation); in-flight cache hit (replay the same `command_id`; verify the second call uses the cached bead ID and does NOT re-invoke `br create`); non-Beads project (no `:create` in capabilities; verify the hook is a no-op and `external_id` remains `nil`); watcher-import branch (synthesize `task.create` via `dispatch_system/2` with `external_id: bead.id`; verify `BeadsAdapter.create/2` is NOT invoked and the bead ID is preserved on the pers…

**PR 2 shippable:** `foreman task create --project-id <beads-backed> --title "..."` produces a `TaskCreated` event with `external_id` populated via the synchronous two-stage hook. The watcher and orphan janitor are not yet booted (they are opt-in via `start_beads_watcher?` / `start_beads_orphan_janitor?` flags; PR 3 activates them).

### PR 3 — Watcher + orphan janitor + opt-in supervision
| id | task | est. | deps | satisfies | validates |
|---|---|---|---|---|---|
| TRD-015-TASK | Implement `ForemanServer.TaskProviders.BeadsWatcher` — supervised GenServer; one process per registered project; state `%{project_id, jsonl_path, file_handle, read_offset, partial_line}`; on `init/1`: resolve JSONL path via `BrRunner.run(["where", "--db", db_path, "--json"])`, open file with `:file.open/2` `[:read, :binary, :raw]`, run `BeadsWatcher.boot_replay/1` (reads offset 0 → EOF, applies parse + dedupe + dispatch pipeline; emits `[:watcher, :replay_started]` / `[:watcher, :replay_completed]`), set `read_offset` to the byte position of the START of any unterminated JSONL fragment (or the file size if the file ends on a terminator) and `partial_line` to the cached fragment bytes (or `""` if the file ends on a terminator), then schedule `Process.send_after(self(), :read_more, @poll_ms)` (default 2s) | M | — | REQ-022 | AC-022-1, AC-022-4 |
| TRD-016-TASK | In `BeadsWatcher.read_more/1` (tail mode): seek to `read_offset`, read bytes to current EOF (do NOT prepend `partial_line`), split on newlines — for each COMPLETE line: parse JSON; check `agent_context.foreman` (skip + emit `[:watcher, :skipped]`); check `ProjectionStore` for `external_id == bead.id` (no-op + emit `[:watcher, :reconciled]`); otherwise synthesize a `task.create` command envelope with `external_id: bead_id` and dispatch via `CommandGateway.dispatch_system/2` (emit `[:watcher, :imported]`). **Trailing-line buffer (single-cursor invariant — 3-way cursor priority):** `read_offset` is the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED — (a) the start byte of the first transient complete-line if the loop stopped at a transient; (b) the start byte of any trailing fragment if the file ends on an unterminated JSONL line; (c) the file size (EOF) if the file ends on a terminator. `partial_line` is the bytes of the FIRST LINE NOT TERMINALLY DISPATCHED — the transient-line bytes from the split if the loop stopped at a transient; the trailing fragment bytes from `last_segment` if the file ends on an unterminated JSONL line; or `""` if the file ends on a terminator and the loop processed all lines terminally. `partial_line` is kept for observability only and is never required for correctness on the next poll (the file read on the next poll seeks to `read_offset` and reads to EOF — the fragment at the seat, if any, is part of the read result and is re-read on transient retries; do NOT prepend `partial_line`). On a terminal advance, `read_offset` is moved past `byte_size(line) + 1` (the line and its terminator); on a transient dispatch, `read_offset` is held and the loop stops (the first transient complete-line is seated at `read_offset` — it is re-read on the next poll, dispatched with the same deterministic `command_id`, and processing continues with any queued lines behind it; if a trailing fragment is also present, it is resolved after the transient-line is terminally dispatched). **Offset advance — terminal set:** the dispatch return value is matched against the EXHAUSTIVE terminal set defined in §2.2.2 (paragraph "Terminal vs transient dispatch outcomes"). The classification uses the FULL gateway return shape — the outer `{:error, _}` wrapper is part of the classifier. Five wrapped shapes are terminal: (a) `{:ok, _}`; (b) `{:error, {:already_exists, :task, _}}`; (c) `{:error, {:invalid_task_status, _}}`; (d) `{:error, {:project_archived, _}}`; (e) `{:error, :project_id_required}`. On a terminal outcome the `read_offset` advances to the post-dispatch byte position. Every other shape — `{:error, {:missing_or_invalid, :task_id, _}}`, `{:error, {:wrong_expected_version, _, _}}`, the 3-tuple `{:error, term(), term()}`, `{:exit, _}`, and any `ProviderError` shape — is **transient**: `read_offset` is held and the same deterministic `command_id` is retried on the next `:read_more` poll. The classification is implemented as a single `case` over the gateway return with the five terminal arms above plus a fallback `_ -> :transient` clause; each terminal arm uses the exact wrapped shape (note that arms (b)/(c)/(d) match 2-/3-tuple reasons while arm (e) matches a bare atom inside the wrapper — the `case` patterns are intentionally arity-distinct). `ProviderError` is never produced by the watcher-import branch (the branch dispatches via `dispatch_system/2` directly into `handle_command/2`, bypassing `BeadsAdapter.create/2` per AC-020-6); any `ProviderError` reaching the classifier is transient by design. Same function is called by `BeadsWatcher.boot_replay/1` on `init/1` for the offset-0 read. | M | TRD-015-TASK | REQ-022 | AC-022-1, AC-022-2, AC-022-3 |
| TRD-017-TASK | Implement `ForemanServer.TaskProviders.BeadsOrphanJanitor` — supervised GenServer; one process per registered project; first scan on `@grace_ms` expiry (default 300s); subsequent scans on `@scan_interval_ms` (default 60s) | M | — | REQ-023 | AC-023-1 |
| TRD-018-TASK | In `BeadsOrphanJanitor.scan/1`: read JSONL; filter for `agent_context.foreman`; for each match, check `ProjectionStore` for the corresponding task's existence and status; for case (a) no task → close with `transition_comment: "foreman-orphan:no-task"`; for case (b) task closed/failed → close with `transition_comment: "foreman-orphan:terminal-task"`; for non-foreman-tagged beads → skip with `[:foreman_server, :task_provider, :beads, :orphan, :janitor, :retained]`. **NEW:** extract `BeadsAdapter.recognise_foreman_tag/1` helper returning `%{command_id: ..., task_id: ..., origin: ..., linked_at: ...} \| :not_foreman`; implement the `foreman doctor task_provider` handler that scans the JSONL, partitions beads into Foreman-managed and external, and emits a per-project summary listing Foreman-tagged beads (`bead_id`, `task_id`, `command_id`, `linked_at`) and the orphan backlog count (case (a) + case (b)). The doctor reads-only — no close actions; cleanup is janitor-only. | M | TRD-017-TASK | REQ-021, REQ-023 | AC-023-2, AC-023-3, AC-023-4, AC-021-2 |
| TRD-019-TASK | Extend `ForemanServer.ProjectionStore.apply_event_by_type(state, "TaskCreated", payload)` (lines 775-791) to include `external_id: payload["external_id"]` (or `event_spec.payload.external_id`) in the task map (default `nil` for legacy events); idempotency is provided by the aggregate's stream-version semantics, not by a separate handler | S | TRD-011-TASK | REQ-025 | AC-025-1 |
| TRD-020-TASK | Add `maybe_beads_watcher_child/0` and `maybe_beads_orphan_janitor_child/0` to `ForemanServer.Application`; both follow the existing `maybe_json_schema_cache_child/0` / `maybe_project_provider_projector_child/0` pattern; opt-in via `:start_beads_watcher?` / `:start_beads_orphan_janitor?` config flags (default `false`); update `config/test.exs` to set both flags to `false`; update `config/runtime.exs` to document the flags | S | TRD-016-TASK, TRD-018-TASK | REQ-022, REQ-023 | AC-022-4, AC-023-1 |
| TRD-021-TASK | Write `beads_watcher_test.exs` — boot replay (full read of offset 0 → EOF, applies dedupe + suppress + dispatch pipeline); verify each line takes the right branch (foreman-tagged → `[:watcher, :skipped]`; already-imported → `[:watcher, :reconciled]`; new operator bead → `[:watcher, :imported]`; `[:watcher, :replay_started]` / `[:watcher, :replay_completed]` emitted with `lines_processed` / `lines_imported` / `lines_suppressed` / `lines_reconciled`); tail mode captures the boot-completion cursor (fragment seat or file size) and subsequent `:read_more` reads from `read_offset` to EOF; transient dispatch failure does NOT advance `read_offset` and retries with the same deterministic `command_id`; single-cursor invariant (3-way cursor priority): `read_offset` is the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED — (a) the start byte of the first transient complete-line if the loop stopped at a transient; (b) the start byte of any trailing fragment if the file ends on an unterminated JSONL line; (c) the file size (EOF) if the file ends on a terminator. `partial_line` is the bytes of the FIRST LINE NOT TERMINALLY DISPATCHED — transient-line bytes from the split, trailing fragment bytes from `last_segment`, or `""` respectively (observability only). On a terminal advance, `read_offset` is moved past `byte_size(line) + 1` (the line and its terminator); on a transient dispatch, `read_offset` is held and the loop stops (the first transient complete-line is seated at `read_offset` — it is re-read on the next poll, dispatched with the same deterministic `command_id`, and processing continues with any queued lines behind it); **boot fragment retention test** — fixture ends with an unterminated fragment (e.g. `{"id":"bead-9","title":"bootstrap-frag`); the watcher boots, reads offset 0 → EOF, processes complete lines, and on completion sets `read_offset` to the byte position of the fragment START (not the EOF); `partial_line` is the cached fragment. Subsequent `:read_more` polls (no new bytes yet) re-read the fragment from `read_offset`; once a subsequent writer appends a newline-completing suffix, the next poll splits the now-complete line and dispatches it — no head-of-file rewrite, no fragment loss; **boot transient retention test** — fixture contains a transient complete-line followed by N queued complete-lines (e.g. `{"id":"bead-3",...}\n{"id":"bead-4",...}\n{"id":"bead-5",...}\n`); the watcher boots, reads offset 0 → EOF, dispatches `bead-3` and the dispatch returns transient (e.g. `{:error, %ProviderError{retryable?: true, code: "BR_TIMEOUT_SUBPROCESS"}}`); the loop stops at the transient, `read_offset` HOLDS at the byte position of `bead-3`'s start (NOT advanced to `bead-4`'s start); `partial_line` is the cached bytes of `bead-3`. Subsequent `:read_more` polls (no new bytes yet) re-read from `read_offset` and re-attempt `bead-3` with the same deterministic `command_id`. Once the transient is resolved to a terminal, the watcher advances `read_offset` past `bead-3` and dispatches `bead-4` and `bead-5` — lines 4..5 are NOT skipped or duplicated; AC-022-2 dedupe via `ProjectionStore` short-circuits already-imported beads on replay | M | TRD-016-TASK, TRD-020-TASK | REQ-022 | AC-022-1, AC-022-2, AC-022-3 |
| TRD-022-TASK | Write `beads_orphan_janitor_test.exs` — grace-window semantics (no scan before grace expires); case (a) `no-task` close; case (b) `terminal-task` close; non-foreman-tagged bead is skipped (with `[:foreman_server, :task_provider, :beads, :orphan, :janitor, :retained]` telemetry); the `BeadsAdapter.complete/3` call carries the correct transition-comment; **`BeadsAdapter.recognise_foreman_tag/1` unit test** — assert the helper returns the parsed tag map for valid JSONL lines, returns `:not_foreman` for lines without `agent_context.foreman`, and returns `:not_foreman` for malformed JSON. **NEW `foreman_doctor_test.exs`** — `foreman doctor task_provider` partition test (Foreman-tagged beads listed with `task_id`, `command_id`, `linked_at`; non-foreman beads listed separately or omitted); orphan backlog count test (count = case (a) + case (b) from a fixture JSONL). | M | TRD-018-TASK, TRD-020-TASK | REQ-021, REQ-023 | AC-021-2, AC-023-1, AC-023-2, AC-023-3, AC-023-4 |
| TRD-023-TASK | Update `docs/user-guide.md` per `foreman-doc-gate` skill — per-project `task_provider` registration extension (`:create` capability), watcher / janitor opt-in semantics, `foreman doctor task_provider` orphan backlog lines, `foreman task create` output shape (bead ID printed when present) | M | TRD-020-TASK | (docs) | (docs) |
| TRD-024-TASK | Update `docs/cli-reference.md`, `README.md`, `CLAUDE.md` — `foreman task create` output shape; `foreman doctor task_provider` adds watcher / janitor / orphan backlog lines; `--json` output now includes `external_id` when the project is Beads-backed; high-level overview of the synchronous create + bi-directional sync with compensating consistency; boundary reminder on the Actor hook insertion point (`aggregate/actor.ex` lines 156-223 are the synchronous hook insertion point, NOT the aggregate handlers) | S | TRD-020-TASK | (docs) | (docs) |
**Shippable State:** The bi-directional sync is live. The watcher forwards Beads-side issues to Foreman; the orphan janitor closes the Foreman-side strands. The flags `:start_beads_watcher?` / `:start_beads_orphan_janitor?` default to `false` in `config/test.exs` and are documented in `config/runtime.exs`. The `foreman doctor task_provider` handler (TRD-018 + TRD-022) reports Foreman-managed beads and the orphan backlog count.

**PR 3 shippable:** The bi-directional sync is live. With `:start_beads_watcher?` and `:start_beads_orphan_janitor?` set to `true` in `config/runtime.exs`, the supervisor boots `BeadsWatcher` and `BeadsOrphanJanitor` per registered project. A `foreman task create` for a Beads-backed project materialises a bead synchronously with the synchronous in-process all-or-nothing guarantee (and compensating recovery for the residual cases); an operator-managed bead whose title matches a Foreman project's intent is auto-imported by the watcher; orphaned foreman-tagged beads are recovered by the janitor within the grace window.
---

## 4. Sprint Planning

The work ships as **3 PRs** (each PR is a single sprint). Sprints are sequenced to maximise independence and minimise review surface area. The earlier 4-PR split that included a `TaskBeadLinked` linkage event is gone: advisory #6 deleted the `TaskBeadLinked` event and the codec dual-registration architecture entirely, and the slice invariant ("every domain event is emitted by an aggregate's `handle_command/2`") is now satisfied by the single-event design — the bead-linkage signal rides on `TaskCreated.external_id`, which is enriched via the second `handle_command/2` invocation in the Actor hook.

### Sprint 1 — PR 1: `TaskProvider` behaviour extension + `BeadsAdapter.create/2`
- **Tasks:** TRD-001-TASK through TRD-009-TASK (9 tasks)
- **Effort:** S mostly, TRD-003-TASK and TRD-009-TASK are M
- **Owner:** one engineer (the `:create` callback, the CodeMap rows, the capabilities change, the test suite)
- **Review surface:** `task_provider.ex`, `task_provider_test.exs`, `beads_adapter.ex`, `beads_adapter_code_map.ex`, the new `test/foreman_server/task_providers/beads_adapter_create_test.exs`
- **Exit criteria:** `BeadsAdapter.create/2` is runnable end-to-end with mocked `BrRunner`; 5 CodeMap rows map correctly; capabilities advertisement includes `:create`; the behaviour-test callback count is 12 and includes `{:create, 2}`; an Actor invocation that exercises the path will get the bead ID from the mocked subprocess without yet wiring the synchronous hook (the synchronous hook lands in Sprint 2).

### Sprint 2 — PR 2: Actor hook + in-flight cache + watcher-import branch + CommandGateway boundary invariant
- **Tasks:** TRD-010-TASK through TRD-014-TASK (5 tasks)
- **Effort:** M mostly, TRD-011-TASK is M (the load-bearing hook; describes the two-stage finalization contract)
- **Owner:** one engineer (the synchronous hook, the in-flight cache, the watcher-import branch, the boundary invariant, the Actor test suite)
- **Review surface:** `aggregate/actor.ex`, `command_gateway.ex`, the new `test/foreman_server/aggregate/actor_hook_test.exs`
- **Exit criteria:** `foreman task create --project-id <beads-backed> --title "..."` produces a `TaskCreated` event with `external_id` populated via the synchronous two-stage hook; `:wrong_expected_version` retry consults the in-flight cache and reuses the cached bead ID (no second `br create`); retry-exhausted compensation closes the bead via `BeadsAdapter.complete/3` with the deterministic `transition_comment` and clears the cache (CLOSE-ONLY-ONCE); the watcher-import branch (`payload["external_id"]` pre-populated) skips `BeadsAdapter.create/2`; `CommandGateway.dispatch_operator/2` rejects` task.create` with non-nil `external_id` at the envelope allowlist (`dispatch_system/2` is unchanged); non-Beads projects emit `TaskCreated` with `external_id: nil` (legacy behaviour).

### Sprint 3 — PR 3: Watcher + orphan janitor + opt-in supervision
- **Tasks:** TRD-015-TASK through TRD-024-TASK (10 tasks)
- **Effort:** M mostly, the docs tasks (TRD-023-TASK, TRD-024-TASK) are M-S
- **Owner:** one engineer (the watcher + janitor GenServers, the supervision tree, the projection map extension, the documentation)
- **Review surface:** `task_providers/beads_watcher.ex`, `task_providers/beads_orphan_janitor.ex`, `application.ex`, `projection_store.ex`, `config/test.exs`, `config/runtime.exs`, the new `beads_watcher_test.exs`, `beads_orphan_janitor_test.exs`, `docs/user-guide.md`, `docs/cli-reference.md`, `README.md`, `CLAUDE.md`
- **Exit criteria:** With `:start_beads_watcher?` and `:start_beads_orphan_janitor?` set to `true`, the bi-directional sync is live; the watcher suppresses foreman-tagged beads and routes non-foreman beads through `CommandGateway.dispatch_system/2`; the janitor closes foreman-tagged orphans on the grace-window schedule (default 300s); the orphan janitor NEVER closes a non-foreman-tagged bead; the projection map stores `external_id` on `TaskCreated`.
## 5. AC Traceability

| AC | Master Task | Validates | Notes |
|---|---|---|---|
| AC-020-1 (synchronous create in Actor hook — happy path) | TRD-011-TASK, TRD-014-TASK | REQ-020 | Actor test asserts the bead ID returned by `BeadsAdapter.create/2` flows into `event_spec.payload.external_id` and the normalized event data carries it on the `TaskCreated` recorded event. Happy-path verification only — the failure path is AC-020-5. |
| AC-020-2 (round-trip through projection) | TRD-019-TASK, TRD-014-TASK | REQ-020, REQ-025 | Projection test asserts `external_id` is in the task map after rebuild of the `TaskCreated` event. |
| AC-020-3 (compensation on append-conflict) | TRD-012-TASK, TRD-014-TASK | REQ-020 | Actor test asserts that on `:wrong_expected_version` (cache hit), the cache is consulted, no second `br create` is issued, and the re-decide with enriched payload is used. On retry exhaustion the Actor closes the bead via `BeadsAdapter.complete/3` with the deterministic `transition_comment` and emits `[:create, :compensated]`. |
| AC-020-4 (per-project gate via capabilities) | TRD-006-TASK, TRD-007-TASK, TRD-011-TASK, TRD-014-TASK | REQ-020 | Actor test asserts the hook is a no-op when `provider_capabilities_for(state, cmd).supports` does not include `:create`; the `TaskCreated` event is emitted with `external_id: nil` (legacy behaviour). |
| AC-020-5 (failure-as-error contract) | TRD-011-TASK, TRD-014-TASK | REQ-020 | Actor test asserts `BeadsAdapter.create/2` returning `{:error, %ProviderError{code: code, retryable?: retryable, ...}}` returns `{:error, %ProviderError{}}` from `do_dispatch/4` without invoking stage 3 (`handle_command/2` re-decide), without invoking `normalize_to_event_data`, and without calling `EventStore.append_to_stream`. No `TaskCreated` event is emitted, no Foreman task is created. Telemetry `[:foreman_server, :task_provider, :beads, :create, :failure]` carries `command_id`, `code`, `retryable?`, `task_id`, `project_id`. |
| AC-020-6 (watcher-import branch — pre-populated `external_id`) | TRD-011-TASK, TRD-014-TASK, TRD-016-TASK | REQ-020 | Actor test asserts that when `cmd.payload["external_id"]` is pre-populated (synthesised by the watcher via `dispatch_system/2`), the Actor skips stage 2 entirely and proceeds to stage 3 with the bead ID already in the payload. No `BeadsAdapter.create/2` invocation. |
| AC-020-7 (CommandGateway boundary invariant) | TRD-013-TASK, TRD-014-TASK | REQ-020 | `CommandGateway.dispatch_operator/2` unit test asserts `task.create` with non-nil `payload.external_id` is rejected with `{:error, :external_id_not_allowed_via_operator}`. `dispatch_system/2` is unchanged. The Actor does NOT duplicate this check (single source of truth). |
| AC-021-1 (`agent_context` tag contains 4 fields) | TRD-003-TASK, TRD-009-TASK | REQ-021 | Test asserts the constructed `--agent-context` JSON shape contains all four fields: `foreman.task_id`, `foreman.command_id`, `foreman.origin` (literal `"foreman"`), `foreman.linked_at` (ISO8601 UTC). The fields are escaped per `BeadsAdapter.scrub_argv/1` per `PRD-2026-48f7b420` REQ-019. |
| AC-021-2 (orphan janitor + `foreman doctor` recognise tag) | TRD-018-TASK, TRD-022-TASK | REQ-021 | Janitor test asserts `agent_context.foreman.command_id` is consulted on the recovery path; `foreman doctor task_provider` test asserts the operator read path recognises the tag and reports the bead as Foreman-managed. Watcher suppression (AC-022-3) is a separate AC. |
| AC-021-3 (tag fields are exact) | TRD-003-TASK, TRD-009-TASK | REQ-021 | Test asserts the four tag fields (`task_id`, `command_id`, `origin`, `linked_at`) are always present in the JSON output and are passed through verbatim — no remapping, no truncation, no silent dropping. `origin` is the literal string `"foreman"`; `linked_at` is ISO8601 UTC. |
| AC-022-1 (watcher boot replay + tail mode + offset advance rule + 3-way cursor priority + boot fragment retention + boot transient retention) | TRD-015-TASK, TRD-016-TASK, TRD-021-TASK | REQ-022 | Watcher test asserts the boot replay reads the JSONL from offset 0 to current EOF, applies the dedupe + suppress + dispatch pipeline to every line, emits `[:watcher, :replay_started]` / `[:watcher, :replay_completed]` with `lines_processed` / `lines_imported` / `lines_suppressed` / `lines_reconciled`, then sets `read_offset` to the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED (3-way cursor priority) — (a) the start byte of the first transient complete-line if the loop stopped at a transient; (b) the start byte of any trailing fragment if the file ends on an unterminated JSONL line; (c) the file size (EOF) if the file ends on a terminator — and `partial_line` to the bytes of that first undispatched line (transient-line bytes, trailing fragment bytes, or `""` respectively), and schedules `Process.send_after(self(), :read_more, @poll_ms)`. **Boot fragment retention test:** the test fixture ends with an unterminated fragment (e.g. `{"id":"bead-9","title":"bootstrap-frag`); the watcher boots, reads offset 0 → EOF, processes complete lines, and on completion sets `read_offset` to the byte position of the fragment START (not the EOF); `partial_line` is the cached fragment. On subsequent `:read_more` polls (no new bytes yet), the watcher reads from `read_offset` to EOF and re-reads the fragment; once a subsequent writer appends a newline-completing suffix, the next poll splits the now-complete line and dispatches it — no head-of-file rewrite, no fragment loss. **Boot transient retention test:** the test fixture contains a transient complete-line followed by N queued complete-lines (e.g. `{"id":"bead-3",...}\n{"id":"bead-4",...}\n{"id":"bead-5",...}\n`); the watcher boots, reads offset 0 → EOF, dispatches `bead-3` and the dispatch returns transient (e.g. `{:error, %ProviderError{retryable?: true, code: "BR_TIMEOUT_SUBPROCESS"}}`); the loop stops at the transient, `read_offset` HOLDS at the byte position of `bead-3`'s start (NOT advanced to `bead-4`'s start); `partial_line` is the cached bytes of `bead-3`. Subsequent `:read_more` polls (no new bytes yet) re-read from `read_offset` and re-attempt `bead-3` with the same deterministic `command_id`. Once the transient is resolved to a terminal, the watcher advances `read_offset` past `bead-3` and dispatches `bead-4` and `bead-5` — lines 4..5 are NOT skipped or duplicated. **Offset-advance classifier — terminal set (5 arms, wrapped):** the test asserts the dispatch classifier matches the FULL gateway return shape (the outer `{:error, _}` wrapper is part of the classifier) with five distinct wrapped terminal arms — (a) `{:ok, _}`; (b) `{:error, {:already_exists, :task, _}}` (3-tuple reason); (c) `{:error, {:invalid_task_status, _}}` (2-tuple reason); (d) `{:error, {:project_archived, _}}` (2-tuple reason); (e) `{:error, :project_id_required}` (bare-atom reason) — plus a fallback `_ -> :transient` clause. Each terminal arm is stubbed separately via Mox with the exact wrapped shape (e.g. `expect(gateway, :dispatch_system, fn _, _ -> {:error, {:already_exists, :task, "bead-7"}} end`); on a terminal return the test asserts `read_offset` advances to the post-dispatch byte position, while on a transient return the test asserts `read_offset` is held and the same deterministic `command_id` is retried on the next `:read_more` poll. **Complementary transient test:** the test additionally stubs `dispatch_system/2` to return `{:error, %ProviderError{retryable?: true, code: "BR_TIMEOUT_SUBPROCESS"}}`, `{:error, {:wrong_expected_version, 5, 6}}`, and `{:exit, :killed}` respectively and asserts all three are classified transient (no `read_offset` advance). **Forward-compatibility note:** `ProviderError` is NEVER produced by the watcher-import branch in production — the branch dispatches via `CommandGateway.dispatch_system/2` directly into the aggregate's `handle_command/2` and bypasses `BeadsAdapter.create/2` (the synchronous `br create` hook is skipped per AC-020-6). The `ProviderError` stub in the transient test is defensive scaffolding: if a future change ever makes the branch emit `ProviderError` (e.g. via a new gateway decorator or a retry-stage decorator), the classifier will reject it as transient and the test will catch a regression to a wrong classification. The terminal set is closed; implementers MUST NOT introduce additional terminal atoms without bumping the TRD/PRD. Tail-mode test additionally asserts the **single-cursor invariant (3-way cursor priority)**: `read_offset` is the byte position of the START of the FIRST LINE NOT TERMINALLY DISPATCHED — (a) the start byte of the first transient complete-line if the loop stopped at a transient; (b) the start byte of any trailing fragment if the file ends on an unterminated JSONL line; (c) the file size (EOF) if the file ends on a terminator. `read_offset` does NOT advance on transient dispatch failure (retried with the same deterministic `command_id`); on every poll the watcher reads from `read_offset` to EOF (the fragment at the seat, if any, is part of the read result and is re-read on transient retries; no `partial_line` prepending); on terminal advance `read_offset` is moved past `byte_size(line) + 1` (the line and its terminator); `partial_line` is the bytes of the FIRST LINE NOT TERMINALLY DISPATCHED — transient-line bytes from the split, trailing fragment bytes from `last_segment`, or `""` respectively (observability only, NOT required for correctness); and on a transient dispatch the transient-line seat is preserved at `read_offset` so the next poll re-reads the transient line (with the same deterministic `command_id`) and continues with the queued lines behind it (no duplication, no loss, no skipping). |
| AC-022-2 (synthetic create envelope for non-foreman beads) | TRD-016-TASK, TRD-021-TASK | REQ-022 | Watcher test asserts the synthetic envelope is dispatched via `CommandGateway.dispatch_system/2` with `payload.external_id` set to the bead ID, and the trusted-system path is used (operator path is rejected by AC-020-7). |
| AC-022-3 (skip foreman-tagged beads) | TRD-016-TASK, TRD-021-TASK | REQ-022 | Watcher test asserts the skip and `[:foreman_server, :task_provider, :beads, :watcher, :skipped]` telemetry on the `agent_context.foreman` path. |
| AC-022-4 (opt-in flag controls supervisor) | TRD-015-TASK, TRD-020-TASK, TRD-021-TASK | REQ-022 | Application boot test asserts the watcher child is added when `:start_beads_watcher?` is `true` and absent otherwise. `config/test.exs` sets the flag to `false`; `config/runtime.exs` documents the flag. |
| AC-023-1 (janitor boot + grace-window semantics) | TRD-017-TASK, TRD-020-TASK, TRD-022-TASK | REQ-023 | Janitor test asserts the first scan happens after `@grace_ms` expiry (default 300s); subsequent scans on `@scan_interval_ms` (default 60s). |
| AC-023-2 (case (a) `no-task` close) | TRD-018-TASK, TRD-022-TASK | REQ-023 | Janitor test asserts the `foreman-orphan:no-task` `transition_comment` is passed to `BeadsAdapter.complete/3` when the projection lookup finds no corresponding task. |
| AC-023-3 (case (b) `terminal-task` close) | TRD-018-TASK, TRD-022-TASK | REQ-023 | Janitor test asserts the `foreman-orphan:terminal-task` `transition_comment` is passed when the task exists but is terminal (closed/failed). |
| AC-023-4 (skip non-foreman-tagged beads) | TRD-018-TASK, TRD-022-TASK | REQ-023 | Janitor test asserts the skip and `[:foreman_server, :task_provider, :beads, :orphan, :janitor, :retained]` telemetry on the non-foreman-tagged path (found-but-skipped, distinct from the watcher `[:skipped]` event on AC-022-3). |
| AC-024-1 (cache lookup before `br create`) | TRD-010-TASK, TRD-011-TASK, TRD-014-TASK | REQ-024 | Actor test asserts `state.in_flight_beads[cmd.command_id]` is consulted before `BeadsAdapter.create/2`; on cache hit the `br create` call is skipped and the cached bead ID is reused for stage-3 re-decide. On cache miss the `br create` call is issued and the returned `bead_handle` is stored under `command_id`. |
| AC-024-2 (cache cleared on terminal) | TRD-010-TASK, TRD-012-TASK, TRD-011-TASK, TRD-014-TASK | REQ-024 | Actor test asserts the `command_id` entry is removed from `in_flight_beads` only on terminal success (after append confirmation) and on terminal compensation (after `br close` completes). The cache is NEVER cleared between append attempts — only on terminal success or terminal compensation, never on transient `:wrong_expected_version`. |
| AC-024-3 (cache is process-local) | TRD-010-TASK, TRD-014-TASK | REQ-024 | Actor test asserts the cache is empty after a simulated crash + supervisor restart. The replay via `Aggregate.load/2` commits the append outcome; if the append had succeeded the bead ID is in the event and the next command proceeds normally; if not, the orphan janitor (REQ-023) absorbs the gap. |
| AC-024-4 (cache keyed by `command_id`) | TRD-010-TASK, TRD-014-TASK | REQ-024 | Actor test asserts two concurrent `task.create` commands for different `command_id`s do not collide on the bead ID lookup. The cache is a `:map` keyed by `command_id`, not a single slot. |
| AC-025-1 (projection map stores `external_id`) | TRD-019-TASK, TRD-014-TASK | REQ-025 | Projection test asserts `ProjectionStore.apply_event_by_type(state, "TaskCreated", payload)` writes `external_id: payload["external_id"]` (default `nil` for legacy events) into the task map alongside the existing fields. The new field is inserted after `task_id` and is always present. Idempotency is provided by the aggregate's stream-version semantics, not by a separate handler. |
| AC-025-2 (capabilities advertises `:create`) | TRD-006-TASK, TRD-002-TASK | REQ-025 | `task_provider_test.exs` assertion: `BeadsAdapter.capabilities().supports` includes `:create` (now `[:claim, :close, :reopen, :annotate, :set_priority, :set_assignee, :list_dependencies, :add_dependency, :remove_dependency, :create]`). The capability test asserts the new entry and the callback count (12 rather than 11). |
| AC-025-3 (callback count 12 + `:create` tuple) | TRD-001-TASK, TRD-002-TASK | REQ-025 | `task_provider_test.exs` assertions: `length(callbacks) == 12` at lines 12 AND 24; `assert {:create, 2} in callbacks` after the existing `add_dependency` assertion. Both line-12 and line-24 length assertions are kept (the duplicate is intentional, matches the existing test). |
| AC-026-1 (INVALID_TITLE CodeMap row) | TRD-005-TASK, TRD-009-TASK | REQ-026 | CodeMap test translates the `br create` VALIDATION envelope (hint `title required`) into `%ProviderError{code: "INVALID_TITLE", retryable?: false, ...}`. `BeadsAdapter` test asserts the rejection surfaces at the adapter boundary. |
| AC-026-2 (INVALID_PRIORITY CodeMap row) | TRD-005-TASK, TRD-008-TASK, TRD-009-TASK | REQ-026 | CodeMap test + BeadsAdapter test + pre-emptive validation test (out-of-range priority `P0..P4` rejected before argv construction). The `INVALID_PRIORITY` row is non-retryable. |
| AC-026-3 (INVALID_ISSUE_TYPE CodeMap row) | TRD-005-TASK, TRD-008-TASK, TRD-009-TASK | REQ-026 | CodeMap test + BeadsAdapter test + pre-emptive validation test (out-of-enum `task_type` rejected before argv construction). The `INVALID_ISSUE_TYPE` row is non-retryable. Symmetric with AC-026-2. |
| AC-026-4 (DUPLICATE_TASK_ID CodeMap row) | TRD-005-TASK, TRD-009-TASK | REQ-026 | CodeMap test translates the `br create` DUPLICATE envelope (rare; can occur if a bead with the same logical content is created concurrently) into `%ProviderError{code: "DUPLICATE_TASK_ID", retryable?: false, ...}`. The caller is expected to re-decide or surface to the operator. |
| AC-026-5 (CREATE_FAILED fallback CodeMap row) | TRD-005-TASK, TRD-004-TASK, TRD-009-TASK | REQ-026 | CodeMap test + BeadsAdapter test. The `CREATE_FAILED` fallback row carries `retryable?: true` (the failure may be transient — signal, timeout, generic envelope, unexpected exit code). `BR_TIMEOUT_SUBPROCESS` mapping is consulted per call. The fallback follows the unknown-code policy from PRD-2026-48f7b420 REQ-008-2: `retryable?` is propagated from `br.retryable`. |
## 6. Traceability Validation

The PRD's 7 requirements (REQ-020 through REQ-026) map to 30 acceptance criteria and 24 master tasks across 3 PRs. The matrix above shows 1-to-1 traceability from each AC to the task(s) that satisfy it and the test(s) that validate it. Every PRD requirement has at least one AC whose validation is a named test file.

**Coverage:** 30 ACs / 30 ACs covered. 24 master tasks / 24 master tasks. 7 REQs / 7 REQs.

**Task-ID ranges per PR:**
- PR 1 (`TaskProvider` behaviour + `BeadsAdapter.create/2`): TRD-001-TASK through TRD-009-TASK (9 tasks) — covers REQ-020 (Actor-hook payload plumbing), REQ-021 (tag fields), REQ-025 (capabilities + callback count + projection map), REQ-026 (5 CodeMap rows).
- PR 2 (Actor hook + in-flight cache + watcher-import branch + boundary invariant): TRD-010-TASK through TRD-014-TASK (5 tasks) — covers REQ-020 (synchronous hook, capabilities gate, compensation, boundary invariant, watcher-import branch) and REQ-024 (cache semantics).
- PR 3 (Watcher + orphan janitor + opt-in supervision + doctor + docs): TRD-015-TASK through TRD-024-TASK (10 tasks) — covers REQ-021 (`foreman doctor` recognition), REQ-022 (watcher), REQ-023 (janitor), and documentation.

**Architectural invariants enforced:**

1. **CommandGateway boundary invariant** (REQ-020 / AC-020-7) — TRD-013-TASK extends `ForemanServer.CommandGateway.dispatch_operator/2` to reject `task.create` envelopes with non-nil `payload.external_id` at the existing envelope allowlist guard, returning `{:error, :external_id_not_allowed_via_operator}`. `dispatch_system/2` is unchanged and remains the trusted path for the watcher-import branch (AC-020-6). The Actor does NOT duplicate this check — single source of truth at the boundary.

2. **In-flight cache invariants** (REQ-024 / AC-024-1..4) — TRD-010-TASK adds `state.in_flight_beads: %{command_id => bead_handle}` to the Actor state struct; TRD-011-TASK inserts the cache-lookup stage into `do_dispatch/4`; TRD-014-TASK validates the four cache ACs via the actor test suite. Specifically:
   - AC-024-1: cache consulted BEFORE `BeadsAdapter.create/2`; on hit, the cached bead ID is reused (no second `br create`).
   - AC-024-2: cache cleared ONLY on terminal success (after append confirmation) or terminal compensation (after `br close` completes). NEVER cleared between append attempts — protects one-`br create`-per-`command_id` against create-close-recreate oscillation.
   - AC-024-3: cache is process-local; empty after crash + supervisor restart; orphan janitor (REQ-023) absorbs the gap.
   - AC-024-4: cache is a `:map` keyed by `command_id`, not a single slot; concurrent commands for different `command_id`s do not collide.

3. **Slice invariant preservation** — there is NO `TaskBeadLinked` event, NO codec dual-registration, and NO second append. The bead-linkage signal rides entirely on the existing `TaskCreated.external_id` field. The Actor enriches the COMMAND payload (not the event spec) and re-invokes `handle_command/2` so the aggregate itself emits the enriched event. This satisfies the slice invariant ("every domain event is emitted by an aggregate's `handle_command/2` routed through `CommandRouter` — no module emits events directly").

4. **Single `ProviderError` factory** (inherited from PRD-2026-48f7b420 REQ-008-5a, extended by this TRD) — TRD-005-TASK adds 5 new CodeMap rows (`INVALID_TITLE`, `INVALID_PRIORITY`, `INVALID_ISSUE_TYPE`, `DUPLICATE_TASK_ID`, `CREATE_FAILED`); all `%ProviderError{...}` struct literals still live inside `BeadsAdapter.CodeMap`. The existing `provider_error_factory_test.exs` architecture test continues to walk the codebase and pass.

5. **Per-project gate** (REQ-020 / AC-020-4) — TRD-006-TASK extends `BeadsAdapter.capabilities/0` to advertise `:create`; TRD-007-TASK wires `TaskProvider.Registry.route/2` to dispatch `:create` to the same per-project state. The Actor hook (TRD-011-TASK) is a no-op when `provider_capabilities_for(state, cmd).supports` does not include `:create`; the `TaskCreated` event is emitted with `external_id: nil` (legacy behaviour). Non-Beads projects skip the synchronous create entirely.

6. **`command_id` dedup** (CommandRouter's existing invariant) — the single append uses the operator-issued `command_id`; retries by the same operator reuse the same `command_id` and are dropped at the CommandRouter dedup gate before reaching the Actor. The `in_flight_beads` cache key is the FIRST command's `command_id`; the cache survives conflict-recovery recursion because it lives on `state.in_flight_beads` (process-local, NOT request-local).

7. **Orphan janitor close-only-our-orphans** (REQ-023 / AC-023-4) — TRD-018-TASK scopes the janitor to beads carrying `agent_context.foreman`; the close-only-our-orphans property is enforced by the tag filter, not by checking the bead ID against Foreman's internal state. Non-foreman-tagged beads are skipped with `[:foreman_server, :task_provider, :beads, :orphan, :janitor, :retained]` telemetry (AC-023-4, distinct from the watcher `[:skipped]` event on AC-022-3).

8. **Watcher-import branch** (REQ-020 / AC-020-6 + REQ-022 / AC-022-2) — TRD-011-TASK detects pre-populated `cmd.payload["external_id"]` at stage 1 and skips stage 2 entirely; TRD-016-TASK synthesizes the envelope via `CommandGateway.dispatch_system/2` (trusted path) so the bead on disk is preserved.

**Test baseline:**
- The slice is run against the project's pre-existing test suite. Pre-existing failures in suites outside this slice's scope (`Recovery`, `StuckDetector`, `AgentRuntime.*`, `Overwatch.*`, `Inbox.*`, `ProjectRegistrySupervisor*`, `RouterOptimisticConcurrency`, `DoctorTaskProviderTest`) are out-of-scope for this TRD; the baseline count is to be re-validated before merge per `/ensemble:implement-trd-beads`.
- Existing test suite targets `mix test test/foreman_server/architecture_test.exs test/foreman_server/workflow_test.exs test/foreman_server/task_providers/enforcement_test.exs` → 92 tests, 0 failures.
- The slice adds: 24 master tasks (TRD-001-TASK through TRD-024-TASK), 6 new test files (`beads_adapter_create_test.exs`, `actor_hook_test.exs`, `beads_watcher_test.exs`, `beads_orphan_janitor_test.exs` (includes the `BeadsAdapter.recognise_foreman_tag/1` unit test), `foreman_doctor_test.exs`, `projection_store_task_external_id_test.exs`), and 1 modified test file (`task_provider_test.exs` extended for the callback count + capabilities assertion).
- The slice does NOT regress the existing 92-test Architecture / Workflow / Enforcement suite.

---

## 7. Next Steps

1. **Run `/ensemble:refine-trd`** to validate the trace matrix, the architecture decision, and the 3-PR task list against the PRD's 7 requirements. Refine any task row that fails the trace validation.
2. **Open PR 1 (`TaskProvider` behaviour extension + `BeadsAdapter.create/2`)** — start with TRD-001-TASK through TRD-009-TASK (9 tasks). Verify the `BeadsAdapter.create/2` callback is runnable end-to-end with a mocked `BrRunner` before merging. The 5 CodeMap rows must be exercised in the test suite; the behaviour-test callback count is 12 and includes `{:create, 2}`. `foreman doctor task_provider` and the watcher / janitor are NOT in this PR.
3. **Open PR 2 (Actor hook + in-flight cache + watcher-import branch + CommandGateway boundary invariant)** — start with TRD-010-TASK through TRD-014-TASK (5 tasks). The boundary-invariant test (TRD-013-TASK) and the actor-hook test (TRD-014-TASK, covers all 5 Actor scenarios: happy path, append-conflict, in-flight cache hit, non-Beads project, watcher-import branch) are the load-bearing PR-2 deliverables. The watcher and orphan janitor are NOT in this PR.
4. **Open PR 3 (Watcher + orphan janitor + opt-in supervision + `foreman doctor` + docs)** — start with TRD-015-TASK through TRD-024-TASK (10 tasks). The watcher (TRD-015, TRD-016, TRD-021) and the orphan janitor (TRD-017, TRD-018, TRD-022, including the `foreman doctor task_provider` handler + test) activate under the opt-in flags `:start_beads_watcher?` and `:start_beads_orphan_janitor?` (TRD-020), both defaulting to `false` in `config/test.exs`. Docs (TRD-023, TRD-024) ship in the same PR.
5. **After PR 3 merges:** the bi-directional sync is live. `foreman task create --project-id <beads-backed>` materialises a bead synchronously with the in-process all-or-nothing guarantee (and compensating recovery for the residual cases); an operator-managed bead whose title matches a Foreman project's intent is auto-imported by the watcher; orphaned foreman-tagged beads are recovered by the janitor within the grace window. The dispatcher operator (a future PRD) will pick up the orphan backlog, the `foreman bead audit` CLI, and `task.update` flows as next-on-deck work.

---

## 8. Changelog

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
