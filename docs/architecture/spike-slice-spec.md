# Spike: Vertical Slice — Go/Elixir CQRS/ES Backend

## Goal

Validate a greenfield Go CLI + Elixir ES/CQRS backend implementing the full
Project → Task → Run → worker completion → projection loop correctly, before
committing to rescuing or replacing the current repo.

**Stack**: Commanded (aggregate supervision, ES/CQRS), EventStore (persistence),
Postgrex (driver), Phoenix (HTTP API boundary for Go CLI). Commanded owns aggregate
lifecycle (append, rehydration, `:permanent` restart). Phoenix receives commands from
Go CLI and dispatches to Commanded — no direct event writes from Go.

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
Commanded owns aggregate lifecycle: append, rehydration, `:permanent` restart.

## Acceptance Criteria

### AC1 — Supervised Actor: Serialized Commands, Stream Rehydration, Event Ordering

**Framework under test**: Commanded `Commanded.Aggregate` — supervised aggregate processes
managed by `Commanded.Aggregates.Supervisor`. Commanded aggregate processes own append,
rehydration, and `:permanent` restart internally. The spike tests that these guarantees
hold for `Project`, `Task`, `Run`, `Worker`, and `Phase` aggregates.

Asserted behaviors:

1. **Serialization**: While `RunAggregate."run-1"` is processing a command, a concurrent
   `sendCommand` for `run-1` from another process is queued in that aggregate's mailbox
   and processed after the current command completes. No race between two concurrent
   commands to the same aggregate instance.

2. **Stream rehydration on startup**: `RunAggregate."run-1"` is started and sent its
   first command. Before handling the command, Commanded replays the aggregate's event
   stream via `apply/2`. The aggregate's in-memory state matches the event stream —
   not a blank slate. Verified by reading aggregate state after startup.

3. **Crash + automatic restart**: `RunAggregate` is a supervised child with
   `restart: :permanent`. After `Process.exit(pid, :kill)`, Commanded's aggregate
   supervisor restarts it automatically. The restarted aggregate rehydrates from the
   event stream before processing the next command.

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

1. Send `run.complete` for `run-1` with `sequence: 1`.
2. Send a second `run.complete` for `run-1` with `sequence: 1` (duplicate).
3. Verify the second command is idempotent — one `RunCompleted` event appended,
   not two.
4. Send `run.complete` for `run-1` with `sequence: 3` (skipping 2).
5. Verify the command is rejected or handled per defined ordering policy
   (reject / buffer / apply optimistically).
6. Verify the aggregate state is consistent with the applied events.

### AC3 — Optimistic Concurrency

1. Send `run.start` — event stream version is N.
2. Concurrently, from another process, send a conflicting command for `run-1`
   that mutates state (e.g., `run.complete`).
3. Verify the first command to arrive succeeds.
4. Verify the second is rejected with a concurrency conflict error
   (`{:error, {:conflict, ...}}`).
5. Verify no partial state is written.

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

- Commanded aggregate processes (`Commanded.Aggregate`) are supervised by
  `Commanded.Aggregates.Supervisor` with `restart: :permanent`.
- Commanded owns append, rehydration, and concurrency internally — these are
  not implemented by the spike's application code.
- Aggregate handlers (`use Commanded.Aggregate, …`) define `execute/2` for command
  handling and `apply/2` for event application. They do not call `EventStore` directly.

### Phoenix Is the Sole HTTP Ingress

- Phoenix receives all HTTP commands from Go CLI via `POST /api/commands`.
- Phoenix dispatches to Commanded's application (e.g. `ForemanApp.dispatch(command)`).
- No other module (worker, Go CLI, or other Elixir code) writes to the event store
  directly. All mutations route through Phoenix → Commanded.

### Architecture Test

- An ExUnit architecture test (`CommandRouterEnforcement` test) verifies that
  `EventStore.append/1` is called only from within Commanded's internal modules
  (or from a single thin wrapper inside the application).
- Any direct `EventStore.append` call from outside the Commanded/Router boundary
  causes the architecture test to fail.

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
RunAggregate."run-1"           ◄── Commanded aggregate process (supervised)
    │
    ▼
Run.execute(command, state)     ◄── execute/2 returns event struct
    │
    ▼
Commanded appends event        ◄── Commanded handles this internally
    │
    ▼
Run.apply(event, state)        ◄── apply/2 mutates aggregate state
    │
    ▼
{:ok, event, new_state} returned to Commanded, Committed via HTTP response
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

| Layer             | Current Repo (POC)                        | Spike Target                     |
|-------------------|-------------------------------------------|----------------------------------|
| Go CLI / dispatch  | Node/TypeScript                          | Go                               |
| Cockpit client     | Go                                       | Go (unchanged)                   |
| Worker protocol    | Node/TypeScript                          | Pi-native or Go↔Elixir           |
| Domain aggregates | Elixir                                   | Elixir (same, Commanded-style)   |
| Actor supervision  | `RunActor` `:temporary` — no restart      | Commanded `:permanent` supervised |
| Event routing     | 16 direct appenders                      | Phoenix → Commanded Router only  |
| VCS / worktree    | Node (vcs-backend)                       | Go + Elixir commands             |
| ForemanStore      | Node (disabled no-op shell)               | Gone                             |
| writeElixirOrchestrationEvent | Node (bypasses CommandRouter) | Gone                          |

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
      → **Resolved by AC1**: supervised actors with `Aggregate.load/2` on restart.
- [ ] What is the idempotency key strategy for duplicate worker completion events?
      → **Resolved by AC2**: defined and tested.
- [ ] Does the Go CLI need a local event log buffer for offline operation?
      → **Out of scope for slice** — slice assumes always-online.
- [ ] Is `Aggregate.load/2` fast enough for every command, or is caching required?
      → **Resolved by slice measurement** — target is <5ms per load.
