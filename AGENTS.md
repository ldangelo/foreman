# Foreman — Agent Context

## Documentation Discipline

Every fix or feature must consider documentation before finalization. Update `CLAUDE.md`, `AGENTS.md`, `README.md`, the Foreman User Guide (`docs/user-guide.md`), and the CLI Reference (`docs/cli-reference.md`) when behavior, commands, workflows, prompts, setup, troubleshooting, or operator expectations change. Keep edits surgical; document only real behavior.

Runtime prompt/workflow safety: after editing bundled source workflows or prompts, run `foreman init --force`. Dispatch paths (`foreman run`, `foreman run --watch`, and direct worker startup) fail fast when installed runtime prompts/workflows are stale.

Local development uses the checked-in Devbox/direnv Docker Compose stack: `devbox run dev:up` starts shared pgvector Postgres plus Hindsight. `.envrc` sources `.env`; treat `.env`'s `DATABASE_URL` as the source of truth for Foreman. The compose stack's fresh/default Postgres port is `127.0.0.1:55432`, but local checkouts may intentionally point `DATABASE_URL` elsewhere.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:

- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

READ ./CLAUDE.md

Workflow note: PR/merge behavior is controlled by phase-level `checkpointPr: true` on mutating phases plus explicit `create-pr`, `pr-wait`, and `merge` phases. Do not add top-level workflow `merge:` or `pr:` tags.

Execution safety rules:

- Before rerunning a task to validate a fix, ensure the fix is durably committed and available on the active branch being tested.
- Treat "implemented" as meaning: relevant tests/build passed and the work has a concrete commit hash on the branch/workspace that will be used for the rerun.
- Do not benchmark or rerun tasks from a dirty or ambiguous controller workspace state.
- If a task reset, branch cleanup, or workspace cleanup is about to happen while important work is only in the working copy, checkpoint it first via commit or patch export.

---

## Slice: `slices/go-elixir-cqrs`

This branch is a greenfield spike implementing a Go CLI + Elixir ES/CQRS backend.
The rules above continue to apply. The additional rules below are specific to this
slice and supplement — not replace — the standing rules.

### Architecture Decisions (Slice)

#### 1. Event Sourcing Core

**State lives in the event log.** The `foreman_events` Postgres table is the single
source of truth. Aggregate modules (`Run`, `Task`, `Project`) are stateless functions
that rebuild transient in-memory state by folding their event stream via
`Aggregate.load/2`. Projections are read models derived from the event log.

**Command flow**:
```
CommandRouter.handle(command)
    → AggregateRouter.route
    → Aggregate.decide(module, stream_id, type, payload)
    → Aggregate.handle_command(state, command)
    → {:ok, event_spec}
    → EventStore.append(event_spec)   ← sole append point
    → ProjectionStore.apply_event
    → Actor.apply_event              (notify supervised actor)
```

#### 2. Supervised Actors Per Aggregate

Every active aggregate (Project, Task, Run) has one supervised GenServer actor
registered by aggregate ID (`"run:#{run_id}"`). The actor's mailbox serializes all
commands for its aggregate — no two commands to the same aggregate process concurrently.

**Actor lifecycle**:
- **Startup**: actor calls `Aggregate.load/2` to rehydrate from its event stream
  before processing any command.
- **Normal operation**: actor receives command, calls `Aggregate.decide`, returns
  event spec to `CommandRouter`, appends via `CommandRouter`, applies confirmed event
  to in-memory state.
- **Crash + restart**: supervisor restarts actor automatically (`:permanent`). Restarted
  actor rehydrates via `Aggregate.load/2` before processing the next command.
- **Append-then-apply**: actor applies events to in-memory state **only after**
  `EventStore.append` succeeds — not optimistically before.

#### 3. Only CommandRouter Appends

**Only `CommandRouter`** (or a `defp` helper private to `CommandRouter`) calls
`EventStore.append` in production code. No handler, actor, or external module calls
`EventStore.append` directly. This is enforced by an ExUnit architecture test.

#### 4. Node/Worker Sends Commands, Not Events

Node and worker processes send **commands** to the Elixir backend. Commands are
HTTP POSTs to `/api/commands`. Workers send structured events as command payloads
(e.g., `command_type: "worker.event"`). No worker process writes directly to the
event store.

#### 5. CQRS Invariant

- **Commands** mutate state via the event store. All state mutations go through
  `CommandRouter.handle`.
- **Queries** read from the projection store (read model). No writes on the query path.

### Domain Events (Slice)

All authoritative state transitions are domain events persisted in `foreman_events`.
Every event is emitted by an aggregate `handle_command` function routed through
`CommandRouter` — no module emits events directly.

| Event | Emitted by | Effects |
|---|---|---|
| `ProjectRegistered` | `Project.handle_command` | Creates project projection |
| `TaskCreated` | `Task.handle_command` | Creates task projection |
| `TaskUpdated` | `Task.handle_command` | Updates task status |
| `RunStarted` | `Run.handle_command` | Creates run projection, spawns worker |
| `PhaseStarted` | `Phase.handle_command` | Updates run phase |
| `PhaseCompleted` | `Phase.handle_command` | Updates run phase |
| `RunCompleted` | `Run.handle_command` | Marks run terminal |
| `RunFailed` | `Run.handle_command` | Marks run terminal |
| `PrCreated` | `Run.handle_command` | Records PR URL |
| `PrMerged` | `Run.handle_command` | Marks run merged |
| `WorkerHeartbeat` | `worker.event` command | Updates worker projection |
| `ToolCallApproved` | `Overwatch.handle_command` (via `CommandRouter`) | Records tool call decision |
| `ToolCallDenied` | `Overwatch.handle_command` (via `CommandRouter`) | Records tool call decision |

### Idempotency and Concurrency (Slice)

**Idempotency**: Every command carries a unique `command_id`. The event store
deduplicates by `command_id` — appending the same command twice produces one event.

**Optimistic Concurrency**: Every append uses `expected_stream_version`. If the
stream has moved past the expected version, append fails with
`{:error, {:conflict, ...}}`. The command is rejected; the actor's in-memory state
is unchanged.

**Ordering**: Commands to a given aggregate are serialized through the actor's
mailbox. Out-of-order commands are rejected by the aggregate's state machine — the
event ordering is part of the aggregate invariant.

### Go CLI Boundaries (Slice)

The Go CLI never writes to:
- The event store directly
- The projection store directly
- Any Elixir internal state

The Go CLI only:
- Sends commands via `POST /api/commands`
- Queries read models via `GET /api/...`
- Formats and displays output

### Test Architecture (Slice)

- **Unit tests**: aggregate handlers — `handle_command` → event spec, valid transitions
- **Integration tests**: actor startup, mailbox serialization, crash/restart/rehydration
- **Architecture tests**: `EventStore.append` is called only from `CommandRouter`
- **Projection tests**: known event sequence → rebuild → verify read model matches
- **Concurrency tests**: parallel commands to same aggregate, optimistic concurrency conflicts
