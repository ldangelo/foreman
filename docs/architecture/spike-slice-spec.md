# Spike: Vertical Slice — Go/Elixir CQRS/ES Backend

## Goal

Validate a greenfield Go CLI + Elixir ES/CQRS backend implementing the full
Project → Task → Run → worker completion → projection loop correctly, before
committing to rescuing or replacing the current repo.

**Stack**: Commanded (aggregate supervision, ES/CQRS), EventStore (persistence),
Postgrex (driver), Phoenix (HTTP API boundary for Go CLI). Commanded owns aggregate
lifecycle (append, rehydration, `:temporary` restart — lazy reopen on next dispatch).
Phoenix receives commands from Go CLI and dispatches to Commanded — no direct event
writes from Go.

The current repo (`v0.x-poc`) is evidence of current behavior, not target behavior.

---

## Scope: One Closed Loop

```
Go CLI                          Phoenix                       Commanded + EventStore
   |                                |                                    |
   |-- HTTP POST /api/commands --->|                                    |
   |<-- 200 ok --------------------|                                    |
   |                                |-- dispatch(command) --------------->
   |                                |         (aggregate process)         |
   |                                |         (append + rehydrate)        |
   |<-- HTTP GET /api/runs/:id ----|                                    |
```

All HTTP arrows are commands or queries. No direct writes from Go CLI or worker
to the event store. All state mutations route through Phoenix → Commanded.
Commanded owns aggregate lifecycle: append, rehydration, `:temporary` restart (lazy).

---

## Acceptance Criteria

### AC1 — Supervised Actor: Serialized Commands, Stream Rehydration, Event Ordering

**Framework under test**: Commanded `Commanded.Aggregates.Aggregate` — supervised aggregate
processes managed by `Commanded.Aggregates.Supervisor` with `restart: :temporary`.
Commanded aggregate processes own append and rehydration internally. Rehydration is lazy:
on the next dispatch after a crash/exit, Commanded reopens a new process and replays the
event stream before handling the command. The spike tests these guarantees for `Project`,
`Task`, `Run`, `Worker`, and `Phase` aggregates.

Asserted behaviors:

1. **Serialization**: While `RunAggregate."run-1"` is processing a command, a concurrent
   `sendCommand` for `run-1` from another process is queued in that aggregate's mailbox
   and processed after the current command completes. No race between two concurrent
   commands to the same aggregate instance.

2. **Stream rehydration on startup**: `RunAggregate."run-1"` is started and sent its
   first command. Before handling the command, Commanded replays the aggregate's event
   stream via `apply/2`. The aggregate's in-memory state matches the event stream —
   not a blank slate. Verified by reading aggregate state after startup.

3. **Crash + lazy reopen**: Commanded aggregates use `restart: :temporary`. After
   `Process.exit(pid, :kill)`, Commanded does **not** auto-restart the aggregate
   process immediately. On the **next dispatch** to that aggregate, Commanded re-opens
   a new process and replays the event stream before handling the command. No manual
   intervention — but the restart is lazy, not immediate.

4. **Post-restart command correctness**: After restart rehydration (step 3), send
   `run.complete` to the restarted aggregate. The aggregate operates on the correct
   rehydrated state — it does not lose pre-crash events or emit conflicting
   post-crash events.

5. **Append-then-apply ordering**: Commanded appends with `expected_stream_version`.
   If append fails (conflict), the aggregate's in-memory state is **not** mutated.
   Commanded's aggregate process handles this internally; verify by inducing a conflict
   and asserting the aggregate state is unchanged.

6. **No silent event loss on crash**: Any event that was appended before the crash
   is replayed on restart. Any event that was in-flight (produced by the aggregate
   but not yet appended) is absent after restart — confirmed absent, not silently lost.

### AC2 — Duplicate / Out-of-Order Worker Completion

**Idempotency is a domain invariant**, not a Commanded feature. Commanded does not
deduplicate by `command_id`. The aggregate's `execute/2` function tracks processed
`completion_sequence` numbers in its state. On a duplicate `run.complete` with the
same `sequence`, the aggregate emits no event and returns an error tuple — the
command is a no-op.

1. Send `run.complete` for `run-1` with `sequence: 1`.
2. Send a second `run.complete` for `run-1` with `sequence: 1` (duplicate).
3. Verify the second command is idempotent — `execute/2` detects the duplicate
   sequence in aggregate state, emits no event, and returns `{:error, :already_completed}`.
   Only one `RunCompleted` event exists in the event store.
4. Send `run.complete` for `run-1` with `sequence: 3` (skipping 2).
5. Verify the command is rejected — `execute/2` detects the gap and returns
   `{:error, :out_of_order}`.
6. Verify the aggregate state is unchanged after steps 2–5.

### AC3 — Optimistic Concurrency

**Framework behaviour**: Commanded's `Aggregate` subscribes to the event stream via
`EventStore.subscribe`. While `execute/2` is blocked in a `receive`, the GenServer mailbox
cannot run `handle_info/2` — externally appended events arrive as `{:events, events}`
messages and queue behind the blocked `receive`. On `:wrong_expected_version`,
`persist_events/3` calls `AggregateStateBuilder.rebuild_from_events/1` which queries
EventStore for the authoritative event list (including the externally appended event),
**not** from the queued mailbox message. It returns `{:error, :too_many_attempts}` at retry 0.
The aggregate process does **not** exit; it remains alive with rebuilt state.

**Test**: A test-only `execute/2` does a selective `receive` that matches only
`{:release, ^ref}` — it must not consume the queued `{:events, events}` subscription
messages. Dispatch it from a Task holding the `ref`.

1. Start `run-1` aggregate and send `run.start` — stream version N.
2. Dispatch a test-only `run.blocking` command whose `execute/2` reads state, then calls:
   ```
   receive do
     {:release, ^ref} -> event_struct
   after 60_000 -> :timeout
   end
   ```
   The receive is selective — it will not consume `{:events, events}` messages. The
   command is parked in `execute/2`. Dispatch from a Task holding `ref`.
3. While the command is blocked, call `append_to_stream/4` externally to append a
   `RunCompleted` event — stream advances to N+1. The subscription delivers a
   `{:events, events}` message that queues behind the blocked `receive`.
4. Send `send(aggregate_pid, {:release, ref})` to release. The selective `receive`
   matches it (not the queued events message). `execute/2` returns its event struct.
5. Commanded's `persist_events/3` detects `:wrong_expected_version` (stream is N+1, command
   expected N). It calls `AggregateStateBuilder.rebuild_from_events/1` which queries
   EventStore for events up to version N+1 — the externally appended `RunCompleted` is
   included. The queued `{:events, events}` mailbox message is **not** applied (it is
   already-seen by the subscription). With `retry_attempts: 0`,
   `persist_events/3` returns `{:error, :too_many_attempts}`. The aggregate process
   **does not exit**; it remains alive with rebuilt state.
6. Assert the aggregate process is still alive (verified by sending it a message).
7. Assert the aggregate's state reflects the externally-appended `RunCompleted` event
   at N+1 (rebuilt from EventStore, not from the queued mailbox message).
8. Assert no `RunBlocking` event was persisted — the aggregate's command event is absent
   because Commanded rejected the persist after the conflict.

### AC4 — Full Projection Rebuild

1. Populate the event store with a known sequence for `run-1`:
   `RunStarted` → `PhaseStarted` → `PhaseCompleted` → `RunCompleted` → `PrCreated`.
2. Clear the projection store (fresh test instance).
3. Rebuild all projections by replaying the event stream.
4. Verify the rebuilt `runs` projection shows `status: "completed"`,
   `current_phase: nil`, `pr_url: "<url>"`.
5. Verify the rebuilt `tasks` projection shows `status: "merged"`.
6. Verify no events are lost, duplicated, or misattributed during replay.

### AC5 — Happy Path (Closed Loop)

1. Register a project via `project.register` command.
2. Create a task linked to the project via `task.create`.
3. Start a run for the task via `run.start`.
4. Send `run.complete` with `status: "completed"`.
5. Query the run — verify `status: "completed"` and `completed_at` set.
6. Query the task — verify its `status` reflects the run outcome.

### AC6 — Go CLI as Command/Query Client Only

1. Every Go CLI operation maps to one `sendCommand` HTTP POST.
2. Every Go CLI query maps to one HTTP GET against the read model.
3. No Go code writes directly to the event store or projection store.
4. Worker completion is sent as a command (`command_type: "worker.event"` or
   `command_type: "run.complete"`), not a direct event write.

---

## Architecture Rules

### Commanded Owns Aggregate Lifecycle

- Commanded aggregate processes (`@behaviour Commanded.Aggregates.Aggregate`) are supervised
  by `Commanded.Aggregates.Supervisor` with `restart: :temporary` — they are not
  automatically restarted on crash.
- Rehydration is **lazy**: on the next dispatch to an aggregate after a crash/exit,
  Commanded opens a new process and replays the event stream before handling the
  command.
- Aggregate modules implement `@behaviour Commanded.Aggregates.Aggregate` with `execute/2`
  for command handling and `apply/2` for event application. They do not call
  `EventStore` directly.
### Phoenix Is the Sole HTTP Ingress

- Phoenix receives all HTTP commands from Go CLI via `POST /api/commands`.
- Phoenix dispatches to Commanded's application (e.g. `ForemanApp.dispatch(command)`).
- No other module (worker, Go CLI, or other Elixir code) writes to the event store
  directly. All mutations route through Phoenix → Commanded.

### Architecture Test

- An ExUnit architecture test (`EventStore.Enforcement`) scans all `.ex` source files
  under `lib/foreman_server/` for direct operational calls to `append_to_stream` or
  adapter dispatch functions (e.g. `EventStore.append_to_stream(`, `Adapter.dispatch(`).
  Module declarations (`defmodule … do; use EventStore`, `otp_app:` config) are allowed.
  Any match causes the test to fail.

### Command Flow

```
Go CLI
    │
    ▼
Phoenix POST /api/commands
    │
    ▼
ForemanApp.dispatch(command)   ◄── Phoenix dispatches to Commanded
    │
    ▼
ForemanRouter.route(command)   ◄── Commanded.Router
    │
    ▼
RunAggregate."run-1"           ◄── Commanded aggregate process (:temporary, lazy reopen)
    │
    ▼
Run.execute(state, command)    ◄── execute/2 returns event struct
    │
    ▼
Commanded appends event         ◄── Commanded handles this internally
    │
    ▼
Run.apply(state, event)        ◄── apply/2 mutates aggregate state
    │
    ▼
{:ok, event, new_state} returned to Commanded, committed via HTTP response
```

### Query Flow

```
Go CLI
    │
    ▼
Phoenix GET /api/runs/:run_id
    │
    ▼
ProjectionStore.snapshot(run_id)   ◄── read model only, no write
    │
    ▼
Read model returned (no write)
```

---

## What Stays vs Goes

| Layer              | Current Repo (POC)                        | Spike Target                        |
|--------------------|-------------------------------------------|-------------------------------------|
| Go CLI / dispatch   | Node/TypeScript                          | Go                                  |
| Cockpit client     | Go                                       | Go (unchanged)                      |
| Worker protocol    | Node/TypeScript                          | Pi-native or Go↔Elixir              |
| Domain aggregates | Elixir                                   | Elixir (same, Commanded-style)      |
| Actor supervision  | `RunActor` `:temporary` — no restart      | Commanded `:temporary`, lazy reopen |
| Event routing      | 16 direct appenders                      | Phoenix → Commanded Router only     |
| VCS / worktree     | Node (vcs-backend)                       | Go + Elixir commands                |
| ForemanStore       | Node (disabled no-op shell)               | Gone                                |
| writeElixirOrchestrationEvent | Node (bypasses CommandRouter) | Gone                               |

---

## Spike Repo Plan

1. **Tag current `main`**: `git tag v0.x-poc <hash>` — use the current HEAD
   hash (confirm with `git rev-parse HEAD`), not a placeholder name
2. **Push the tag**: `git push origin v0.x-poc`
3. **Branch from `main`**: `slices/go-elixir-cqrs`
4. **Greenfield** — do not copy implementation files from the current repo.
   Copy only `packages/foreman_server/lib/foreman_server/aggregates/` as
   reference material for domain logic.
5. All spike artifacts (AGENTS.md, constitution, spec) live in
   `slices/go-elixir-cqrs` only.
6. Current repo (`main`, `fix/runtime-mode-leak`) continues unchanged.

---

## Open Questions (resolved by the slice)

- [ ] Does `CommandRouter` handle all worker ingress, or does a separate
      `worker_protocol` module still need direct append?
      → **Resolved by AC6**: all worker events route through `CommandRouter`.
- [ ] Is `RunActor` stateless + process registry, or supervised GenServer with
      stream rehydration?
      → **Resolved by AC1**: Commanded `:temporary` aggregates, lazy reopen on next dispatch.
- [ ] What is the idempotency key strategy for duplicate worker completion events?
      → **Resolved by AC2**: domain invariant in `execute/2` — aggregate tracks sequences.
- [ ] Does the Go CLI need a local event log buffer for offline operation?
      → **Out of scope for slice** — slice assumes always-online.
- [ ] Is `Aggregate.load/2` fast enough for every command, or is caching required?
      → **Resolved by slice measurement** — target is <5ms per load.
