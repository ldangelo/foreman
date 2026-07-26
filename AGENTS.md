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

This branch is a greenfield spike implementing a Go CLI + Elixir ES/CQRS backend
using Commanded + Phoenix.
The rules above continue to apply. The additional rules below are specific to this
slice and supplement — not replace — the standing rules.

### Stack (Slice)

- **Commanded**: aggregate supervision, ES/CQRS, command routing
- **EventStore**: event persistence (via Commanded adapter)
- **Postgrex**: Postgres driver
- **Phoenix**: HTTP API boundary for Go CLI; receives commands and dispatches to Commanded

### Architecture Decisions (Slice)

#### 1. Event Sourcing Core

**State lives in the event log.** The `foreman_events` Postgres table is the single
source of truth. Aggregate modules (`Run`, `Task`, `Project`) use `Commanded.Aggregate`
behaviour with `execute/2` for command handling and `apply/2` for event application.
Projections are read models derived from the event log.

**Command flow**:
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
ForemanRouter.route(command)  ◄── Commanded.Router
    │
    ▼
RunAggregate."run-1"           ◄── Commanded supervised aggregate process
    │
    ▼
Run.execute(command, state)    ◄── execute/2 returns event struct
    │
    ▼
Commanded appends internally  ◄── Commanded handles append internally
    │
    ▼
Run.apply(event, state)       ◄── apply/2 mutates aggregate state
```

#### 2. Commanded Owns Aggregate Lifecycle

Commanded aggregate processes are supervised by `Commanded.Aggregates.Supervisor`
with `restart: :permanent`. Commanded owns append, rehydration, and concurrency
internally — these are not implemented by spike application code.

**Actor lifecycle** (Commanded-managed):
- **Startup**: Commanded replays the aggregate's event stream via `apply/2`
  before processing the first command.
- **Normal operation**: aggregate receives command, `execute/2` returns event struct,
  Commanded appends and applies internally.
- **Crash + restart**: supervisor restarts aggregate automatically (`:permanent`).
  Restarted aggregate rehydrates from the event stream before the next command.
- **Append-then-apply**: Commanded guarantees events are appended before `apply/2`
  is called — no optimistic mutations.

#### 3. Phoenix Is the Sole HTTP Ingress

Phoenix receives all HTTP commands from Go CLI via `POST /api/commands`.
Phoenix dispatches to Commanded's application (e.g. `ForemanApp.dispatch(command)`).
No other module (worker, Go CLI, or other Elixir code) writes to the event store
directly. All mutations route through Phoenix → Commanded.

#### 4. Architecture Test

An ExUnit architecture test verifies that `EventStore.append/1` is called only from
within Commanded's internal modules. Any direct `EventStore.append` call from outside
the Commanded/Router boundary causes the test to fail.

#### 5. CQRS Invariant

- **Commands** mutate state via Commanded. All state mutations go through
  Phoenix → Commanded.
- **Queries** read from the projection store (read model). No writes on the query path.

### Domain Events (Slice)

All authoritative state transitions are domain events persisted in `foreman_events`.
Every event is emitted by an aggregate `execute/2` function routed through
`ForemanRouter` — no module emits events directly.

| Event | Emitted by | Effects |
|---|---|---|
| `ProjectRegistered` | `Project.execute/2` | Creates project projection |
| `TaskCreated` | `Task.execute/2` | Creates task projection |
| `TaskUpdated` | `Task.execute/2` | Updates task status |
| `RunStarted` | `Run.execute/2` | Creates run projection, spawns worker |
| `PhaseStarted` | `Phase.execute/2` | Updates run phase |
| `PhaseCompleted` | `Phase.execute/2` | Updates run phase |
| `RunCompleted` | `Run.execute/2` | Marks run terminal |
| `RunFailed` | `Run.execute/2` | Marks run terminal |
| `PrCreated` | `Run.execute/2` | Records PR URL |
| `PrMerged` | `Run.execute/2` | Marks run merged |
| `WorkerHeartbeat` | `worker.event` command | Updates worker projection |
| `ToolCallApproved` | `Overwatch.execute/2` | Records tool call decision |
| `ToolCallDenied` | `Overwatch.execute/2` | Records tool call decision |

### Idempotency and Concurrency (Slice)

**Idempotency**: Commanded deduplicates commands by `command_id` — appending the same
command twice produces one event.

**Optimistic Concurrency**: Commanded uses `expected_stream_version` internally. If the
stream has moved past the expected version, append fails with a concurrency conflict.
The aggregate's in-memory state is unchanged.

**Ordering**: Commands to a given aggregate are serialized through the aggregate's
mailbox. Out-of-order commands are rejected by the aggregate's state machine.

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

- **Unit tests**: aggregate handlers — `execute/2` → event struct, valid transitions
- **Integration tests**: aggregate startup, mailbox serialization, crash/restart/rehydration
- **Architecture tests**: `EventStore.append` is called only from Commanded internals
- **Projection tests**: known event sequence → rebuild → verify read model matches
- **Concurrency tests**: parallel commands to same aggregate, optimistic concurrency conflicts
