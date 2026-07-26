 # Spike: Vertical Slice — Go/Elixir CQRS/ES Backend
 
## Goal
 
 Validate a greenfield Go CLI + Elixir ES/CQRS backend implementing the full
 Project → Task → Run → worker completion → projection loop correctly, before
 committing to rescuing or replacing the current repo.
 
**Stack**: Elixir/OTP (GenServer, Supervisor, Registry), EventStore (persistence),
Postgrex (driver), Phoenix (HTTP API boundary for Go CLI).
Custom `Actor` modules provide aggregate supervision with `:permanent` restart,
`Aggregate.load/2` rehydration, and `apply/2` event application. `CommandRouter` is the
sole append point — no module other than `CommandRouter` calls `EventStore.append_to_stream`.
Phoenix receives commands from Go CLI and dispatches to `CommandRouter` — no direct event writes from Go.
 
 The current repo (`v0.x-poc`) is evidence of current behavior, not target behavior.
 
 ---
 
## Scope: One Closed Loop
 
 ```
 Go CLI                          Phoenix                       Actor + CommandRouter + EventStore
    |                                |                                    |
    |-- HTTP POST /api/commands --->|                                    |
    |<-- 200 ok --------------------|                                    |
    |                                |-- CommandRouter.handle(command) --->|
    |                                |         (Actor process)            |
    |                                |         (Aggregate.load + handle_command) |
    |                                |<-- {:ok, events} ----------------|
    |<-- HTTP GET /api/runs/:id ----|                                    |
 ```
 
 All HTTP arrows are commands or queries. No direct writes from Go CLI or worker
 to the event store. All state mutations route through Phoenix → CommandRouter.
 Custom `Actor` modules are supervised with `:permanent` restart. Rehydration is eager:
 on startup or restart, the Actor calls `Aggregate.load/2` to rebuild state from the
 event stream before handling any command.

---

## Acceptance Criteria

### AC1 — Supervised Actor: Serialized Commands, Stream Rehydration, Event Ordering
 
 **Framework under test**: Custom `Actor` modules supervised with `restart: :permanent`.
 Each actor is a `GenServer` that calls `Aggregate.load/2` on startup/restart to rebuild
 state from the event stream before handling any command. The actor's mailbox serializes
 all commands for its aggregate. `CommandRouter` is the sole append point. The spike
 tests these guarantees for `Project`, `Task`, `Run`, `Worker`, and `Phase` aggregates.

Asserted behaviors:

 1. **Serialization**: While `Actor."run-1"` is processing a command, a concurrent
    `CommandRouter.dispatch` for `run-1` from another process is queued in that actor's mailbox
    and processed after the current command completes. No race between two concurrent
    commands to the same aggregate instance.
 
 2. **Stream rehydration on startup**: `Actor."run-1"` is started and sent its
    first command. Before handling the command, `Aggregate.load/2` replays the aggregate's event
    stream via `apply/2`. The actor's in-memory state matches the event stream —
    not a blank slate. Verified by reading actor state after startup.
 
 3. **Crash + eager reopen with :permanent**: Custom `Actor` supervisors use `restart: :permanent`.
    After `Process.exit(pid, :kill)`, the supervisor restarts the actor immediately.
    On restart, `Aggregate.load/2` replays the event stream before the actor handles any command.
    No manual intervention — the restart is immediate (not lazy), and rehydration is eager.
 
 4. **Post-restart command correctness**: After restart rehydration (step 3), send
    `run.complete` to the restarted actor. The actor operates on the correct
    rehydrated state — it does not lose pre-crash events or emit conflicting
    post-crash events.
 
 5. **Append-then-apply ordering**: `CommandRouter` appends with `expected_stream_version`.
    If append fails (conflict), the actor's in-memory state is **not** mutated —
    no confirmed event is sent to `Actor.apply_event`. The actor remains alive.
    Verify by inducing a conflict and asserting actor state is unchanged.
 
 6. **No silent event loss on crash**: Any event that was appended before the crash
    is replayed on restart via `Aggregate.load/2`. Any event that was in-flight
    (produced by the actor but not yet appended via `CommandRouter`) is absent after restart —
    confirmed absent, not silently lost.

### AC2 — Duplicate / Out-of-Order Worker Completion

**Idempotency via `command_id` deduplication**: every command carries a unique
`command_id`. The event store append deduplicates by `command_id` — appending the
same command twice produces one event. Sequence validation remains as a domain
out-of-order guard in `handle_command` in the aggregate.

1. Send `run.complete` for `run-1` with `command_id: "cmd-1"`, `sequence: 1`.
2. Send a second `run.complete` for `run-1` with `command_id: "cmd-1"` (same id, duplicate).
3. Verify the event store persisted exactly one `RunCompleted` event for `run-1`.
   The second command was deduplicated at append — no second event.
4. Send `run.complete` for `run-1` with `command_id: "cmd-3"`, `sequence: 3`
   (skipping sequence 2, out-of-order).
5. Verify `handle_command` rejects the command — it detects the sequence gap
   and returns `{:error, :out_of_order}`. No event is appended.
6. Verify the aggregate state is unchanged after steps 2–5.

### AC3 — Optimistic Concurrency
 
 **Mandated behaviour**: `CommandRouter` appends with `expected_stream_version`. If the stream
 has advanced (externally appended), the append fails and `CommandRouter` returns the conflict
 error to the caller. No confirmed event is sent to `Actor.apply_event` — the actor's
 in-memory state is unchanged. The actor remains alive.
 
**Test**: A test-only `handle_command` does a selective `receive` matching only `{:release, ref}`
to park without consuming other messages. The test externally appends an event while the
actor is parked, inducing a conflict.

 1. Start `Actor."run-1"` and send `run.start` — stream version N.
 2. Dispatch a test-only command whose `handle_command` parks in selective `receive` waiting for
    `{:release, ref}`. The command is parked; the actor's mailbox queues it.
 3. While parked, externally call `append_to_stream(stream_uuid, N, events)` — stream advances
    to N+1. This simulates an external actor appending to the same stream.
 4. Release the parked command: `send(actor_pid, {:release, ref})`. The actor wakes,
    returns its event struct to `CommandRouter`.
 5. `CommandRouter.append` uses `expected_version: N`, but stream is now N+1 — conflict.
    `CommandRouter` returns the conflict error. **No event is appended** and **no event is
    sent to `Actor.apply_event`**.
 6. Assert the actor is still alive (`:sys.get_state(actor_pid)` proves responsiveness).
 7. Assert the actor's in-memory state is unchanged from step 1 — `apply_event` was never
    called because the conflict prevented any confirmed event.
 8. Assert exactly N+1 events are in the stream — the externally appended one from step 3.
    The actor's pending event was rejected and is absent.
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
 
 1. Every Go CLI operation maps to one `CommandRouter.dispatch` HTTP POST.
 2. Every Go CLI query maps to one HTTP GET against the read model.
 3. No Go code writes directly to the event store or projection store.
 4. Worker completion is sent as a command (`command_type: "worker.event"` or
    `command_type: "run.complete"`), not a direct event write.
 
## Architecture Rules
 
### Custom Actor Supervision
 
Custom `Actor` modules are supervised by a project-specific `Aggregator` supervisor
with `restart: :permanent`. Each active aggregate has one supervised GenServer actor
registered by aggregate ID (`"run:#{run_id}"`). The actor's mailbox serializes all
commands for its aggregate — no two commands to the same aggregate process concurrently.
 
 **Actor lifecycle**:
 - **Startup / restart**: actor calls `Aggregate.load/2` to rehydrate from its event
   stream before processing any command (eager rehydration).
 - **Normal operation**: actor receives command, calls `Aggregate.decide`, returns
   event spec to `CommandRouter`, appends via `CommandRouter`, applies confirmed event
   to in-memory state.
 - **Crash + restart**: supervisor restarts actor automatically (`:permanent`). Restarted
   actor rehydrates via `Aggregate.load/2` before processing the next command.
 - **Append-then-apply**: actor applies events to in-memory state **only after**
   `CommandRouter` append succeeds — not optimistically before.
 
### CommandRouter Is the Sole Append Point
 
 Only `CommandRouter` (or a `defp` helper private to `CommandRouter`) calls
 `EventStore.append_to_stream` in production code. No handler, actor, or external
 module calls `EventStore.append_to_stream` directly. This is enforced by an ExUnit
 architecture test.
 
### Phoenix Is the Sole HTTP Ingress
 
 Phoenix receives all HTTP commands from Go CLI via `POST /api/commands`.
 Phoenix dispatches to `CommandRouter.handle/1`.
 No other module (worker, Go CLI, or other Elixir code) writes to the event store
 directly. All mutations route through Phoenix → CommandRouter.
 
### Architecture Test
 
 An ExUnit architecture test (`EventStore.Enforcement`) scans all `.ex` source files
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
 CommandRouter.handle(command)   ◄── Phoenix dispatches to CommandRouter
     │
     ▼
 Actor."run-1"                  ◄── custom supervised GenServer (:permanent, eager rehydrate)
     │
     ▼
 Aggregate.decide(state, command) ◄── decide/2 returns event spec
     │
     ▼
 CommandRouter.append(event_spec) ◄── sole append point
     │
     ▼
 Actor.apply(state, event)       ◄── apply/2 mutates aggregate state (after append)
     │
     ▼
 {:ok, events, new_state} returned via CommandRouter, committed via HTTP response
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
| Domain aggregates | Elixir                                   | Elixir (same domain, custom Actor modules) |
| Actor supervision  | `RunActor` `:temporary` — no restart      | Custom `Actor` modules, `:permanent`, eager rehydrate via `Aggregate.load/2` |
| Event routing      | 16 direct appenders                      | Phoenix → CommandRouter only (sole append point) |
| VCS / worktree     | Node (vcs-backend)                       | Go + Elixir commands                              |
| ForemanStore       | Node (disabled no-op shell)               | Gone                                             |
| writeElixirOrchestrationEvent | Node (bypasses CommandRouter) | Gone                                              |
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
     → **Resolved by standing rules**: custom `Actor` GenServer supervised with
      `:permanent`; eager rehydration via `Aggregate.load/2` on startup/restart.
- [ ] What is the idempotency key strategy for duplicate worker completion events?
     → **Resolved by AC2**: `command_id` deduplication at event store append;
      sequence gap check in `handle_command` (domain out-of-order guard).
- [ ] Does the Go CLI need a local event log buffer for offline operation?
      → **Out of scope for slice** — slice assumes always-online.
- [ ] Is `Aggregate.load/2` fast enough for every command, or is caching required?
      → **Resolved by slice measurement** — target is <5ms per load.
