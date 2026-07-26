# Spike: Vertical Slice — Go/Elixir CQRS/ES Backend

## Goal

Validate a greenfield Go CLI + Elixir ES/CQRS backend implementing the full
Project → Task → Run → worker completion → projection loop correctly, before
committing to rescuing or replacing the current repo. The slice tests the hard
parts of CQRS/ES — actor supervision and crash recovery, not merely the happy path.

The current repo (`v0.x-poc`) is evidence of current behavior, not target behavior.
`RunActor` with `restart: :temporary` is the POC; supervised actors with stream
rehydration are the target.

---

## Scope: One Closed Loop

```
Go CLI                          Elixir Backend                    Go/Pi Worker
   |                                  |                                  |
   |--- command: project.register --->|                                  |
   |<-- ok ---------------------------|                                  |
   |--- command: task.create -------->|                                  |
   |<-- ok ---------------------------|                                  |
   |--- command: run.start --------->|                                  |
   |                                  |--- worker.launch -------------->|
   |<-- ok ---------------------------|                                  |
   |                                  |<---- command: worker.event ------|
   |                                  |<---- command: worker.event ------|
   |                                  |<---- command: run.complete ------|
   |<-- query: run -------------------|                                  |
   |<-- query: task -----------------|                                  |
   |--- command: run.pr.create ----->|                                  |
   |<-- ok ---------------------------|                                  |
```

All arrows are commands or queries. No direct writes from worker or Go CLI to the
event store. All state mutations route through `CommandRouter.handle`.

---

## Acceptance Criteria

### AC1 — Supervised Actor: Serialized Commands, Stream Rehydration, Event Ordering

**Architecture under test**: one supervised GenServer (`ProjectActor`, `TaskActor`,
`RunActor`) per active aggregate, registered by aggregate ID. The actor's mailbox
serializes all commands for its aggregate. On every startup (first command or crash
restart) the actor rehydrates from its event stream. The actor calls the aggregate
handler which returns `{:ok, event_spec}`. `CommandRouter` appends with
`expected_stream_version`. The actor applies the committed event to its in-memory
state **only after** the append succeeds — not optimistically before.

Asserted behaviors:

1. **Serialization**: While `RunActor` for `run-1` is processing a command, a
   concurrent `sendCommand` for `run-1` from another process is queued in the
   actor's mailbox and processed after the current command completes. No race
   between two concurrent commands to the same aggregate.

2. **Stream rehydration on startup**: `RunActor` for `run-1` is started and sent its
   first command. Before handling the command, the actor calls
   `Aggregate.load(Run, "run:#{run_id}")` and applies the resulting state.
   The actor's in-memory state matches the event stream — not a blank slate.

3. **Crash + automatic restart**: `RunActor` is a supervised child (`:permanent`).
   After `Process.exit(pid, :kill)`, the supervisor restarts it automatically.
   The restarted actor rehydrates from the event stream before processing the next
   command. No manual intervention, no blank state.

4. **Post-restart command correctness**: After restart rehydration (step 3), send
   `run.complete` to the restarted actor. The actor operates on the correct
   rehydrated state — it does not lose pre-crash events or emit conflicting
   post-crash events.

5. **Append-then-apply ordering**: `CommandRouter` appends with
   `expected_stream_version`. If append fails (conflict), the actor's in-memory
   state is **not** mutated. The actor applies the event only after confirmed
   append. Verify this by inducing a conflict and asserting the actor's GenServer
   state is unchanged.

6. **No silent event loss on crash**: Any event that was appended before the crash
   is replayed on restart. Any event that was in-flight (written by the actor but
   not yet appended) is absent after restart — confirmed absent, not silently lost.

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

### Only `CommandRouter` Appends

- **Only** `CommandRouter` (or a `defp` helper within it) calls `EventStore.append`
  in the production slice.
- Aggregate handlers return `{:ok, event_spec}`; `CommandRouter` appends and
  then the aggregate's `apply_event` mutates the in-memory aggregate state.
- No handler, actor, or external module calls `EventStore.append` directly.

### Actors Return Events, Not Direct Writes

- Actors (`RunActor`, `TaskActor`, `ProjectActor`) receive commands, call
  `Aggregate.decide`, and return the event spec to `CommandRouter`.
- `CommandRouter` appends, then notifies the actor so it can apply the event
  to its in-memory state.
- Actor state is derived from the event stream on startup and after restart.

### Command Flow

```
Go CLI / Worker
    │
    ▼
HTTP POST /api/commands
    │
    ▼
CommandRouter.handle(command)
    │
    ├──► AggregateRouter.route(command_type, payload)
    │         │
    │         └──► Aggregate.decide(Run, "run:#{run_id}", command_type, payload)
    │                    │
    │                    └──► Run.handle_command(state, command)
    │                              │
    │                              └──► {:ok, event_spec}
    │
    ├──► EventStore.append(event_spec)   ◄── sole append point
    │
    ├──► ProjectionStore.apply_event(event)
    │
    ├──► Actor.apply_event(event)   (notify supervised actor)
    │
    └──► {:ok, result} returned to caller
```

### Query Flow

```
Go CLI
    │
    ▼
HTTP GET /api/runs/:run_id
    │
    ▼
ProjectionStore.snapshot
    │
    ▼
Read model returned (no write)
```

---

## What Stays vs Goes

| Layer             | Current Repo (POC)                        | Spike Target              |
|-------------------|-------------------------------------------|--------------------------|
| Go CLI / dispatch  | Node/TypeScript                          | Go                       |
| Cockpit client     | Go                                       | Go (unchanged)           |
| Worker protocol    | Node/TypeScript                          | Pi-native or Go↔Elixir   |
| Domain aggregates | Elixir                                   | Elixir (same)            |
| Actor supervision  | `RunActor` `:temporary` — no restart      | Supervised `:permanent`   |
| Event routing     | 16 direct appenders                      | `CommandRouter` only     |
| VCS / worktree    | Node (vcs-backend)                       | Go + Elixir commands     |
| ForemanStore      | Node (disabled no-op shell)               | Gone                     |
| writeElixirOrchestrationEvent | Node (bypasses CommandRouter) | Gone                 |

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
