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

- **ForemanServer.Aggregate**: behaviour defining `initial_state/0`,
  `handle_command/2`, `apply_event/2` callbacks
- **ForemanServer.Aggregate.Actor**: supervised GenServer holding in-memory
  aggregate state and stream version; routes commands through `CommandRouter`
- **CommandRouter**: single append point for all domain events
- **EventStore** (via Commanded adapter): event persistence
- **Postgrex**: Postgres driver
- **Phoenix**: HTTP API boundary for Go CLI

### Architecture Decisions (Slice)

#### 1. Event Sourcing Core

**State lives in the event log.** The `foreman_events` Postgres table is the single
source of truth. Aggregate modules (`Run`, `Task`, `Project`) implement the
`ForemanServer.Aggregate` behaviour with `handle_command/2` for command handling
and `apply_event/2` for event application. Projections are read models derived
from the event log.

**Command flow**:
```
Go CLI
    │
    ▼
Phoenix POST /api/commands
    │
    ▼
CommandRouter.dispatch(command)  ◄── CommandRouter.dispatch/1
    │
    ▼
Aggregator.start_aggregate(module, id)  ◄── starts Actor if not running
    │
    ▼
Actor.handle_call(:command, cmd)  ◄── Actor calls aggregate directly
    │
    ▼
aggregate.handle_command(state, cmd)  ◄── handle_command/2 returns event spec
    │
    ▼
Actor sends event spec to CommandRouter  ◄── send CommandRouter, {:append, ...}
    │
    ▼
EventStore.append_to_stream  ◄── CommandRouter is sole append point
    │
    ▼
CommandRouter sends {:append_ok, count} back to Actor  ◄── append confirmed
    │
    ▼
Actor calls aggregate_module.apply_event/2  ◄── state updated after confirm
```

**Actor lifecycle** (`Aggregator` manages with `restart: :permanent`):
- **Startup**: `Actor.init` calls `Aggregate.load/2` which replays the event stream
  via `apply_event` before processing any command.
- **Normal operation**: actor receives command, calls `handle_command`, sends event spec
  to `CommandRouter`, awaits append confirmation, then calls `apply_event` to update state.
- **Crash + eager restart**: `Aggregator` supervisor restarts the actor immediately
  (`restart: :permanent`). Restarted actor rehydrates via `Aggregate.load/2` before
  processing the next command.

#### 2. Aggregate State Design
**Every aggregate's fixed top-level state MUST be a dedicated `%Aggregate.State{}`
struct. Maps are permitted only as nested genuinely dynamic values.**


Each aggregate defines a nested `State` struct:

```elixir
defmodule ForemanServer.Aggregates.Run do
  defmodule State do
    defstruct [:exists?, :run_id, :status, :terminal?,
               phase_status: %{}, worker_status: %{}, retry_history: []]
  end

  @impl true
  def initial_state, do: %State{exists?: false, run_id: nil, status: nil, ...}
end
```

**Why:** Plain maps (`%{exists?: false, ...}`) admit atom/string key drift and
silently accept unknown fields. `Map.merge(state, payload)` in `apply_event`
can add undeclared keys with no warning, causing silent schema drift across
replay. Struct-update syntax (`%State{state | field: value}`) rejects
undeclared fields at compile time (literal unknown atoms) or runtime (`KeyError`
for unknown variable fields). `struct/2` silently ignores unknown keys and
MUST NOT be used.

**Maps for dynamic collections are fine.** Fields like `phase_status`,
`worker_status`, `config`, or `retry_history` — where the shape is genuinely
open or comes from heterogeneous event payloads — may remain maps. The struct
covers the closed aggregate invariant fields; maps cover open metadata.

**Enforcement rules:**

- `apply_event` uses `%State{state | field: value}` — not `Map.merge(state, payload)`,
  not `struct(state, field: value)`.
- Explicit per-event field mapping: `event_type → state field` is written out
  per event type.
- `initial_state/0` returns the State struct with required fields set to defaults.
- **`handle_command` enforces domain invariants.** Struct construction alone does
  not validate state preconditions or valid transitions.

**Required migrations (all under `lib/foreman_server/aggregates/`):**
`Project`, `Run`, `Task`, `Phase`, `Worker`, `OperatorIntervention`, `PlanningFlow`,
`Recovery`, `Scheduler`, `ToolCall`, `VcsOperation`, `ArtifactReport`, `Attachment`,
`ExternalTrigger`, `ImportMigration`, `InboxThread`, `Integration`.
All are now migrated to `%State{}` structs with `%State{state | ...}` updates.

#### 3. Phoenix Is the Sole HTTP Ingress

Phoenix receives all HTTP commands from Go CLI via `POST /api/commands`.
Phoenix dispatches to `CommandRouter.dispatch/1`. No other module (worker, Go CLI,
or other Elixir code) writes to the event store directly. All mutations route
through Phoenix → CommandRouter.

#### 4. Architecture Test

An ExUnit architecture test (`EventStore.Enforcement`) scans all `.ex` source files
under `lib/foreman_server/` for direct operational calls to `append_to_stream` or
adapter dispatch functions. Module declarations (`defmodule … do; use EventStore`,
`otp_app:` config) are allowed. Any match causes the test to fail.

#### 5. CQRS Invariant

- **Commands** mutate state via `CommandRouter`. All state mutations go through
  Phoenix → CommandRouter.
- **Queries** read from the projection store (read model). No writes on the query path.

### Domain Events (Slice)

All authoritative state transitions are domain events persisted in `foreman_events`.
Every event is emitted by an aggregate `handle_command/2` function routed through
`CommandRouter` — no module emits events directly.

| Event | Emitted by | Effects |
|---|---|---|
| `ProjectRegistered` | `Project.handle_command/2` | Creates project projection |
| `TaskCreated` | `Task.handle_command/2` | Creates task projection |
| `TaskUpdated` | `Task.handle_command/2` | Updates task status |
| `RunStarted` | `Run.handle_command/2` | Creates run projection, spawns worker |
| `PhaseStarted` | `Phase.handle_command/2` | Updates run phase |
| `PhaseCompleted` | `Phase.handle_command/2` | Updates run phase |
| `RunCompleted` | `Run.handle_command/2` | Marks run terminal |
| `RunFailed` | `Run.handle_command/2` | Marks run terminal |
| `PrCreated` | `Run.handle_command/2` | Records PR URL |
| `PrMerged` | `Run.handle_command/2` | Marks run merged |
| `WorkerHeartbeat` | `worker.event` command | Updates worker projection |
| `ToolCallApproved` | `ToolCall.handle_command/2` | Records tool call decision |
| `ToolCallDenied` | `ToolCall.handle_command/2` | Records tool call decision |

#### Typed Event Structs

Every domain event is a typed struct in `lib/foreman_server/events/` with `@enforce_keys`
and `@type t`. `%EventData{}` / `%RecordedEvent{}` are persistence envelopes only — they
are not domain types. `EventData.data` / `RecordedEvent.data` holds the serialized domain
struct; on replay, the struct MUST be reconstructed before `apply_event` pattern-matches it.

Canonical event struct (`@derive` before `defstruct`):
```elixir
defmodule ForemanServer.Events.RunCompleted do
  @enforce_keys [:run_id, :sequence]
  @type t :: %__MODULE__{run_id: String.t(), sequence: non_neg_integer(), status: String.t() | nil}
  @derive Jason.Encoder
  defstruct [:run_id, :sequence, status: nil]
end
```

`apply_event` pattern-matches the typed struct directly:
```elixir
def apply_event(state, %RunCompleted{run_id: run_id, sequence: seq}) do
  %State{state | status: "completed", terminal?: true, run_id: run_id, last_sequence: seq}
end
```

`EventCodec.decode!/2` is the replay contract. It reconstructs typed structs from
deserialized data with uniform API `decode!(event_type, data)`: typed structs pass through,
JSON maps are validated and rebuilt. Both paths reject a struct whose module does not
match the `event_type` string. Maps are reserved for genuinely open nested data inside
the event. They MUST NOT replace the typed event struct itself.

### Idempotency and Concurrency (Slice)

**Idempotency**: `CommandRouter` deduplicates by `command_id`. Duplicate commands
produce no additional events. Domain idempotency (e.g. rejecting a second
`run.complete` on an already-completed run) is implemented in each aggregate's
`handle_command/2`.

**Optimistic Concurrency**: Every append uses `expected_stream_version`. If the
stream has moved past the expected version, append fails with a concurrency conflict.
The aggregate's in-memory state is unchanged.

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

- **Unit tests**: aggregate handlers — `handle_command/2` → event spec, valid transitions
- **Integration tests**: aggregate startup, mailbox serialization, crash/restart/rehydration
- **Architecture tests**: no direct `append_to_stream`/adapter calls in `lib/foreman_server/`
- **Projection tests**: known event sequence → rebuild → verify read model matches
