# Architecture, domain events, idempotency, CLI boundaries, tests, TaskProvider, execution safety

> Archived from the former monolithic `AGENTS.md` (2026-10-18), with accuracy corrections from the PR #561 review, to keep the always-loaded agent context small. Stack, command flow, actor lifecycle, aggregate design, event structs, idempotency, TaskProvider behaviour.
> Section-number references inside (e.g. "section 4", "§5.4") point at the pre-split `AGENTS.md`; the §5 rules are summarised in `AGENTS.md` and full text is in `typed-boundaries-full.md`.

## Architecture

### Stack

- **ForemanServer.Aggregate**: behaviour defining `initial_state/0`,
  `handle_command/2`, `apply_event/2` callbacks
- **ForemanServer.Aggregate.Actor**: supervised GenServer holding in-memory
  aggregate state and stream version; routes commands through `CommandRouter`
- **CommandRouter**: single append point for all domain events
- **EventStore** (via Commanded adapter): event persistence
- **Postgrex**: Postgres driver
- **Phoenix**: HTTP API boundary for Go CLI

### Command Flow

```
Go CLI
    │
    ▼
Phoenix POST /api/commands  ◄── CommandController.create/2
    │
    ▼
CommandGateway.dispatch_operator(command)  ◄── enriches the operator command
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

### Actor Lifecycle

`Aggregator` manages actors with `restart: :permanent`:

- **Startup**: `Actor.init` calls `Aggregate.load/2` which replays the event stream
  via `apply_event` before processing any command.
- **Normal operation**: actor receives command, calls `handle_command`, sends event spec
  to `CommandRouter`, awaits append confirmation, then calls `apply_event` to update state.
- **Conflict recovery (bounded retry)**: on `{:error, :wrong_expected_version}` the actor
  reloads state via `Aggregate.load/2`, re-decides via `handle_command/2`, and retries the
  append with the new `expected_stream_version`. Retry is bounded by
  `@max_conflict_retries` (default 3). On exhaustion the actor replies with the telemetry
  tuple `{:telemetry, {:error, {:wrong_expected_version, version}}, %{append_latency_ms: latency}}`
  (`version` is the actor's current stream version); `CommandRouter` unwraps it, so callers
  of `CommandRouter.dispatch/2` receive `{:error, {:wrong_expected_version, version}}`. The
  aggregate state is left unchanged (only the in-flight Beads cache is compensated). A
  re-decision that returns `{:error, _}` (e.g. `:phase_terminal`) terminates the retry
  without appending; the actor replies with that plain error, not a telemetry tuple.
- **Crash + eager restart**: `Aggregator` supervisor restarts the actor immediately
  (`restart: :permanent`). Restarted actor rehydrates via `Aggregate.load/2` before
  processing the next command.

### Aggregate State Design

**Every aggregate's fixed top-level state MUST be a dedicated `%Aggregate.State{}`
struct. Maps are permitted only as nested genuinely dynamic values.**

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
open or comes from heterogeneous event payloads — may remain maps.

**Status: complete.** Every aggregate under `lib/foreman_server/aggregates/`
declares its own `State` struct and updates it with `%State{state | ...}`. This
is now a standing rule for new aggregates, not outstanding migration work — do
not add an aggregate whose state is a plain map.

**Enforcement rules:**

- `apply_event` uses `%State{state | field: value}` — not `Map.merge(state, payload)`,
  not `struct(state, field: value)`.
- Explicit per-event field mapping: `event_type → state field` is written out
  per event type.
- `initial_state/0` returns the State struct with required fields set to defaults.
- **`handle_command` enforces domain invariants.** Struct construction alone does
  not validate state preconditions or valid transitions.

### Phoenix Is the Sole HTTP Ingress

Phoenix receives all HTTP commands from Go CLI via `POST /api/commands` and
dispatches them through `CommandGateway.dispatch_operator/2`, which ends at
`CommandRouter.dispatch/2`. Internal (non-HTTP) mutations come from trusted OTP
code via `CommandGateway.dispatch_system/2`, which calls `CommandRouter`
directly and does not pass through Phoenix. No other module (worker, Go CLI,
or other Elixir code) writes to the event store directly: every append goes
through `CommandRouter`.

### Architecture Test

An ExUnit architecture test (`EventStore.Enforcement`) scans all `.ex` source files
under `lib/foreman_server/` for direct operational calls to `append_to_stream` or
adapter dispatch functions. Module declarations (`defmodule … do; use EventStore`,
`otp_app:` config) are allowed. Any match causes the test to fail.

### CQRS Invariant

- **Commands** mutate state via `CommandRouter`. HTTP mutations go through
  Phoenix → `CommandGateway.dispatch_operator/2` → CommandRouter; internal OTP mutations go through `dispatch_system/2` → CommandRouter.
- **Queries** read from the projection store (read model). No writes on the query path.

### Workflow Catalog Hot-Reload

`ForemanServer.Workflow.Catalog` is a supervised GenServer that owns every
parsed workflow manifest and prompt body in memory and keeps them in sync
with the on-disk root — `~/.foreman/workflows` by default, overridable via
`config :foreman_server, :workflow_root` (`AssetCatalog.default/0` reads
that key first).

- **Auto-install** — `init/1` calls
  `ForemanServer.WorkflowTemplate.Installer` only when the configured root
  contains no `*.yaml` manifests. A populated `prompts/` directory does
  **not** suppress the install; the installer uses `File.cp/2` and
  `File.write/2` and will overwrite any same-named prompt already on
  disk. Keep custom templates under their own filenames.
- **Synchronous load** — every manifest is parsed via
  `ForemanServer.Workflow.Interpreter.load/1` during `init/1` so the first
  command after boot finds the catalog ready. Every `*.md` under
  `prompts/` is loaded the same way.
- **Hot reload** — a periodic poll (default 2s, override via
  `Application.put_env(:foreman_server, :workflow_catalog_poll_ms, ms)`)
  re-hashes every manifest and prompt and replaces any entry whose content
  or mtime changed. Files that vanish are removed from the catalog.
- **Prompt read API** — `Catalog.read_prompt/1` returns the latest prompt
  body. `RunExecutor.read_phase_prompt/2` reads through the catalog so a
  prompt edit is picked up on the next phase.

Telemetry:
`[:foreman_server, :workflow, :installed]`,
`[:foreman_server, :workflow, :manifest, :loaded | :reload, :ok | :reload, :error | :removed]`,
`[:foreman_server, :workflow, :prompt, :loaded | :reload, :ok | :reload, :error | :removed]`.

`[:foreman_server, :skills, :installed]` (measurements `%{count: files_copied}`, metadata
`%{paths: [...]}`) and `[:foreman_server, :skills, :install, :error]` (metadata
`%{reason: term()}`) are emitted by `ForemanServer.Workflow.Catalog`'s boot hook, which
forwards `:skills_home_dir` / `:skills_target_dir` / `:skills_source_dir` (prefixed so they
cannot collide with the workflow-root options the same GenServer accepts) to
`ForemanServer.Skills.Installer.maybe_install/1`. Nothing swallows the result: `{:ok, :noop}`
emits no event, a list of copied paths emits `:installed`, and `{:error, reason}` emits
`:install, :error` — the `_ =` this replaced made a failed skill boot-install invisible (§5.2).

---

## Domain Events

All authoritative state transitions are domain events persisted in `foreman_events`.
Every event is emitted by an aggregate `handle_command/2` function routed through
`CommandRouter` — no module emits events directly.

**Source of truth: `lib/foreman_server/events/`.** `ForemanServer.EventCodec`
derives its registry from that directory at compile time, so
`EventCodec.registered/0` always lists every event struct. The table below is a
**curated subset** for orientation, not an inventory — it is deliberately not
exhaustive (there are currently 87 event structs). Do not treat a missing row
as "this event does not exist", and do not try to keep the table in one-to-one
sync; per **§5.5**, a hand-maintained second list is the defect, not the fix.

| Event | Emitted by | Effects |
| --- | --- | --- |
| `ProjectRegistered` | `Project.handle_command/2` | Creates project projection |
| `ProjectUpdated` | `Project.handle_command/2` | Updates project projection |
| `ProjectArchived` | `Project.handle_command/2` | Archives project projection |
| `TaskCreated` | `Task.handle_command/2` | Creates task projection |
| `TaskApproved` | `Task.handle_command/2` | Transitions task to ready, triggers dispatch |
| `TaskRetried` | `Task.handle_command/2` | Resets task to `open` for re-approval (projection `retry_count` +1) |
| `TaskRunTerminated` | `Task.handle_command/2` | Marks task run-level terminal |
| `TaskDispatched` | `Task.handle_command/2` | Records dispatch on task (`Dispatcher` issues the `task.dispatch` command) |
| `ProjectRunReserved` | `Project.handle_command/2` | Implementation key reservation |
| `RunStarted` | `Run.handle_command/2` | Creates run projection, spawns worker |
| `RunCancelled` | `Run.handle_command/2` | Marks run cancelled; `Dispatcher` also kills the dispatched agent via `RunControl.cancel_agent/1` |
| `RunPaused` | `Run.handle_command/2` | Stops the run resumably; `Dispatcher` kills the dispatched agent (after the executor commits partial work) and releases the run slot/lease without reopening the task |
| `RunResumed` | `Run.handle_command/2` | Re-enters a paused run at its first non-completed phase |
| `RunBaseBranchRecorded` | `Run.handle_command/2` | Persists the run's PR base branch so a resumed run cannot retarget it |
| `RunDeleted`\* | `Run.handle_command/2` | Marks run removed and triggers cleanup fan-out |
| `RunReset`\* | `Run.handle_command/2` | Clears failed/stuck run projection state for fresh submission |
| `RunCompleted` | `Run.handle_command/2` | Marks run terminal success |
| `RunFailed` | `Run.handle_command/2` | Marks run terminal failure |
| `RunFlaggedStuck` | `Run.handle_command/2` | Flags run as stuck (`StuckDetector` issues `run.flag_stuck`) |
| `WorktreeCreated` | `Run.handle_command/2` | Worktree created |
| `WorktreeCleaned` | `Run.handle_command/2` | Worktree cleaned |
| `WorktreeCreateOrphanRecorded` | `Run.handle_command/2` | Records orphan worktree at creation |
| `WorktreeCreateOrphanResolved` | `Run.handle_command/2` | Resolves orphan worktree |
| `PrAssociated` | `PrAssociation.handle_command/2` | Records the PR URL on the run projection and in the `pr_associations` map |
| `PrMerged`\* | `Run.handle_command/2` | Aggregate replay only (no `ProjectionStore` handler found) — treat as unverified read-model effect |
| `PhaseStarted` | `Phase.handle_command/2` | Updates run phase |
| `PhaseCompleted` | `Phase.handle_command/2` | Updates run phase |
| `WorkerHeartbeat` | `Worker.handle_command/2` | Updates worker projection (`Tracker.heartbeat/3` dispatches the `worker.record` command) |
| `ToolCallFinished` | `ToolCall.handle_command/2` | Records the tool-call decision (approve/deny in one event) |
| `VcsOperationStarted` / `VcsOperationCompleted` / `VcsOperationFailed` | `VcsOperation.handle_command/2` | Records VCS operation lifecycle (three events, not one) |
| `BeadsDbLeaseAcquired` | `BeadsDbLease.handle_command/2` | Holder takes the per-DB Beads lease |
| `BeadsDbLeaseReleased` | `BeadsDbLease.handle_command/2` | Holder releases the lease (no waiters) |
| `BeadsDbLeaseWaiterRegistered` | `BeadsDbLease.handle_command/2` | Runner enqueued behind current holder |
| `BeadsDbLeaseWaiterRemoved` | `BeadsDbLease.handle_command/2` | Cancel-before-promotion of a waiter |
| `BeadsDbLeaseTransferred` | `BeadsDbLease.handle_command/2` | Release + head-waiter promotion in one event |

\* `RunDeleted` and `RunReset` (and `PrMerged` above) have no corresponding
struct file under `lib/foreman_server/events/` — `grep -rn "defmodule.*RunDeleted\|defmodule.*RunReset\|defmodule.*PrMerged" lib/`
returns nothing. They are emitted as raw `%{event_type: "RunDeleted", ...}`
maps and consumed by `Run.apply_event/2`'s and `ProjectionStore`'s string-keyed
`case`/`apply_event_by_type` clauses, not via `EventCodec`. This contradicts
the "every event is a typed struct" claim directly below — do not assume it
holds for every row in this table; verify against `lib/foreman_server/events/`
before relying on it.

#### Typed Event Structs

Every domain event *should* be a typed struct in `lib/foreman_server/events/`
with `@enforce_keys` and `@type t`, decoded via `EventCodec.decode!/2` before
`apply_event` pattern-matches it — this is the contract for external
decode/replay paths that go through `EventCodec` (e.g. `ProjectionStore`
rebuild from a cold projection). It is **not** universally true internally:
`Aggregate.load/2` (`aggregate.ex:180-193`) calls `module.apply_event(state,
event)` directly on raw event-store maps with no `EventCodec.decode!` call at
all, so an aggregate's own `apply_event/2` can — and in `Run`'s case, for
`RunDeleted`/`RunReset`/`PrMerged`, does — pattern-match untyped `event_type`
strings that have no registered struct. `%EventData{}` / `%RecordedEvent{}`
are persistence envelopes only — they are not domain types. `EventData.data`
/ `RecordedEvent.data` holds the serialized domain struct where one exists.

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

**Registration is automatic — never hand-maintained.** `EventCodec` builds both
its `event_type → module` registry and its enforced-key lookup at compile time
by scanning `lib/foreman_server/events/`. Adding a struct file registers the
event; deleting the file removes it. Each source is an `@external_resource`, and
`__mix_recompile__?/0` forces a rebuild when a file is added or removed, so the
registry can never go stale.

Adding a new event is therefore one file and no registry edits:

```elixir
defmodule ForemanServer.Events.ThingHappened do
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{run_id: String.t(), detail: String.t() | nil}
  @derive Jason.Encoder
  defstruct [:run_id, detail: nil]
end
```

This replaced two parallel hand-written maps that had already drifted: 15 of 66
event structs — `ProjectRegistered`, `ProjectUpdated`, `ProjectArchived`,
`PrAssociated`, `MergeGate*`, `ScheduledFire*`, `SchedulerIntentStale`,
`RunAlreadyCompleted`, `RunRecoveryEvent`, and all three `VcsOperation*` — were
present on disk but absent from the registry, so decoding them raised
"unregistered event_type" even though the struct existed and was documented.
Do not reintroduce a second list.

---

## Idempotency and Concurrency

**Idempotency**: `CommandRouter` deduplicates by `command_id`. Duplicate commands
produce no additional events. Domain idempotency (e.g. rejecting a second
`run.complete` on an already-completed run) is implemented in each aggregate's
`handle_command/2`.

**A `task.approve` command_id is also the approval's identity.** `CommandGateway` makes it the
`approval_id` and `Identity.run_id/2` derives the run id from it, so re-sending a command_id after
`task.retry` (which returns the task to `open` to be approved *again*) is answered from the event
stream with the ORIGINAL `TaskApproved`: nothing is appended, the task stays `open`, and the caller
sees `{:ok, _}` (foreman-nfizr). A re-approval needs a command_id of its own. `BeadsWatcher` scopes
its deterministic id by the task's `retry_count` (read-model field, +1 per `TaskRetried`):
`beads-cmd:<project>:<bead>:auto-approve` for the first approval, `...:auto-approve:retry-<n>` after
the n-th retry, so one retry's approval delivered twice is still one approval.

**Optimistic Concurrency**: Every append uses `expected_stream_version`. If the
stream has moved past the expected version, append fails with `{:error, :wrong_expected_version}`.
The Actor's bounded retry path intercepts the conflict, reloads the aggregate state via
`Aggregate.load/2`, re-decides via `handle_command/2`, and retries with the new version
(see **Actor lifecycle → Conflict recovery**). On retry exhaustion the actor replies with
`{:telemetry, {:error, {:wrong_expected_version, version}}, ...}`, which `CommandRouter`
unwraps to `{:error, {:wrong_expected_version, version}}` for callers, and the aggregate state
is unchanged; on a re-decision that
rejects (e.g. `:phase_terminal`) the retry terminates without appending — preserving
exactly-once.

**Per-DB Beads lease (write serialization across processes and restarts)**: SQLite's
single-writer protocol cannot tolerate concurrent br/bv writers or writers running
alongside `bv --robot-plan`. The `BeadsDbLease` aggregate is an event-sourced lock
keyed by the configured absolute Beads DB path passed at acquire time, giving
process-local serialization through the Actor mailbox while surviving Foreman
restarts via persisted events. Required because multi-`run_id` parallelism on the
same DB otherwise deterministically raises
`cannot connect to database: locking protocol (15)`. Callers must pass the same
absolute path on every dispatch — symlink aliasing (e.g. `/tmp/...` vs
`/private/tmp/...`) is NOT collapsed and will register separate lease streams.

- **Stream id**: `beads_db_lease:<db_path>` (literal path; see warning above).
- **Acquire**: `lease.acquire` is atomic — if the DB is free, the run becomes holder;
  if held, the run is enqueued as a waiter and admission returns `:queued`.
- **Release**: `lease.release` and `lease.remove_waiter` are dispatched at run
  terminal time (`RunCancelled`, `RunDeleted`, `RunFlaggedStuck`, `RunCompleted`, `RunFailed`,
  `RunBlocked`) by the Dispatcher. Both are idempotent no-ops when the run_id is not
  bound to the lease.
- **Promotion**: when the holder releases with waiters, the aggregate emits a single
  `BeadsDbLeaseTransferred` event that releases the old holder and promotes the
  head waiter, so cancellation cannot race with promotion. The Dispatcher subscribes
  to this event and re-enters `RunAdmission.start/2` for the promoted run.
- **Process-bound holds and restarts** (foreman-w29up): `BeadsDbLease.with_lease/4` — every
  `br` call of `BeadsAdapter`, each `BeadsWatcher` read pass, the orphan janitor — holds the
  lease for one call in one process and tags the hold with the `ForemanServer.Incarnation` of
  the server (`incarnation` in the `lease.acquire` payload, on `BeadsDbLeaseAcquired` and
  `BeadsDbLeaseWaiterRegistered`; `acquired_incarnation` on `BeadsDbLeaseTransferred`). The hold
  is durable but its owner is not: a server killed mid-call (`kill -9`, OOM, a shutdown that
  cuts `try/after`) leaves the hold in the event store. The next incarnation takes it over at
  once (`BeadsDbLeaseAcquired` with `provenance: {:reclaimed_stale_holder, run_id}`) instead of
  queueing behind it until `:lease_timeout`, and `BootReconciliation.scan_lease_orphans/0`
  lists every `beads_db_lease:` stream in the event store (not only the DBs a task projection
  points at: a per-call hold is bound to no task) and releases the holds and waiters of other
  incarnations. Before this, a stranded `watcher:<project>:<ns>` hold made `BeadsWatcher` log
  `lease_acquire failed reason=:lease_timeout, skipping this read cycle` on every poll and
  import nothing. A hold with no `incarnation` (`RunAdmission`'s whole-run hold of an
  `implement-trd-beads` run) belongs to a run and is reclaimed only through run liveness. A
  `:lease_timeout` now logs the holder it queued behind.
- **Callers that die within one incarnation** (foreman-8qge): the incarnation tag separates
  VMs, not processes. A `with_lease/4` caller killed inside a live server
  (`Process.exit(pid, :kill)`, a supervisor's `:shutdown` of a child that does not trap exits,
  a linked crash) never runs its `after`; its hold names a VM that is alive, so nothing could
  call it dead. It blocked every later caller of that Beads database until the next restart
  (`BeadsWatcher` skipped every read cycle with `:lease_timeout`), and a waiter that died in
  the queue was promoted to a hold nobody released. Every `with_lease/4` call is now watched by
  a `BeadsDbLease.Keeper` (under `BeadsDbLease.KeeperSupervisor`, outside every caller's
  subtree) that monitors the caller and, when it goes down, dispatches `lease.remove_waiter`
  and then `lease.release` for its `run_id` (reason `:caller_down`). Takeover assumptions, none
  of them a clock: a hold of another VM incarnation is dead (one server per event store and
  Beads database, else a live hold is taken over); a hold of this VM is dead exactly when the
  process that took it is; a hold whose caller lives is never given up, however long its `br`
  call runs (no TTL). The keeper is armed before `lease.acquire` is dispatched, so no entry of
  a call exists unwatched, and stopped after the caller's own release, so a normal call leaves
  nothing behind (a failed release, `ReleaseError`, leaves it armed). A call that gives up
  (acquire error, `:lease_timeout`) removes its queue entry and then releases too: the run can
  have been promoted between its last poll and the removal, and nothing else would give that
  hold back. A keeper that is killed or crashes while its caller lives is restarted
  (`restart: :transient`; a normal stop is terminal) and the replacement monitors the caller
  afresh (a monitor on a dead pid answers at once), so the caller's later death is still
  answered; one that keeps dying is restarted five times, then logged with `Logger.error`, its
  call running unwatched. A cleanup that arrives late is a no-op: `lease.release` ignores a run
  that is not the holder, so a lease that moved on keeps its new holder. The lease is keyed by
  `run_id`, so two live processes using one `run_id` at once share one hold, which the first to
  finish releases for both, keeper or not.
  A restarted caller reuses its run's `run_id`, so a keeper whose caller died first leaves the
  lease alone while another live call uses the same `run_id` (that call owns the hold now:
  `lease.acquire` is idempotent per run), and a new call waits in `Keeper.watch/4` for the
  keepers of dead callers under its `run_id` before it acquires, so a cleanup still on its way
  cannot release the hold the new call is about to take. Left open: a keeper of a live call
  killed at the very instant the keeper of a dead call under the same `run_id` looks.
  A cleanup that cannot be dispatched is retried, then logged with `Logger.error`; the hold
  stays until a restart or a manual `lease.release`. While `KeeperSupervisor` is not running
  `with_lease/4` returns `{:error, {:lease_keeper_unavailable, reason}}` and takes no lease.
- **Fail-closed gating**: `RunAdmission.start/3` reads the lease decision before
  starting the run supervisor. Any uncertainty (acquire error, atom state of
  `:unknown` or `:unexpected`) returns `{:error, ...}` and skips dispatch. A
  `:queued` decision returns without starting the supervisor; the dispatcher picks
  the run up again on `BeadsDbLeaseTransferred`.
- **Compensation**: `lease.release` on admission failure is only emitted for
  definitively non-retryable rejections (`{:missing_or_invalid, …}`,
  `{:implementation_already_active, …}`, `{:command_rejected, …}`). Compensating
  transient errors would break retry semantics.
- **Scope**: different DBs and direct (`foreman run`) workflows remain parallel.
  The lease keys only on the DB path, never on the run_id.
- **Scope limitation (important)**: the lease governs only admission through
  Foreman. External `br` writers and `bv --robot-plan` invocations launched
  outside Foreman are NOT protected — they must observe single-writer
  discipline themselves. `br_bv_lease_concurrency_test.exs` verifies the
  admission contract; upstream concurrency (e.g. an operator running `br`
  directly while Foreman holds) is the operator's responsibility. The lease
  exists to prevent two Foreman-dispatched runs from racing on the same DB,
  not to mediate file-system access against unrelated processes.

- **Universal backstop**: all `br` invocations through `SystemBrRunner.cmd/3` are
  additionally serialized per `database_path` via `:global.trans/2` as a universal
  backstop. This catches every call site (create, list_ready, update, get, reopen,
  set_priority, ready, coordination_status, and any future callers) without requiring
  `with_lease` wrapping at each one. Covered by `system_br_runner_test.exs`
  concurrency serialization regression test.

---

## Go CLI Boundaries

The Go CLI never writes to:

- The event store directly
- The projection store directly
- Any Elixir internal state

The Go CLI only:

- Sends commands via `POST /api/commands`
- Queries read models via `GET /api/...`
- Formats and displays output

---

## Test Architecture

- **Unit tests**: aggregate handlers — `handle_command/2` → event spec, valid transitions
- **Integration tests**: aggregate startup, mailbox serialization, crash/restart/rehydration
- **Architecture tests**: no direct `append_to_stream`/adapter calls in `lib/foreman_server/`
- **Projection tests**: known event sequence → rebuild → verify read model matches

---

## TaskProvider System

The `TaskProvider` behaviour (`ForemanServer.TaskProvider`) defines the contract for
issue tracker adapters. The existing production adapter is `BeadsAdapter` (backed by
`beads_rust` / `br` CLI). A second adapter, `KataAdapter` (backed by the
`kata` CLI), is designed but not yet implemented — no `task_providers/kata_*`
files exist under `lib/`; see `docs/TRD/TRD-2026-8030852f-foreman-kata-task-provider.md`
(status: Draft) for the plan.

### TaskProvider Behaviour Callbacks

```elixir
@callback name() :: String.t()
@callback provider_id() :: atom()
@callback contract_version() :: String.t()
@callback capabilities() :: map()
@callback available?() :: boolean()
@callback list_ready(project_id :: String.t(), opts :: keyword()) :: {:ok, [Issue.t()]} | {:error, ProviderError.t()}
@callback get(issue_id :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback claim(issue_id :: String.t(), actor :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback complete(issue_id :: String.t(), opts :: keyword()) :: {:ok, Issue.t() | :terminal} | {:error, ProviderError.t()}
@callback fail(issue_id :: String.t(), reason :: String.t(), opts :: keyword()) :: {:ok, :reopened} | {:error, ProviderError.t()}
@callback reopen(issue_id :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback comment(issue_id :: String.t(), body :: String.t(), opts :: keyword()) :: {:ok, Comment.t()} | {:error, ProviderError.t()}
@callback set_priority(issue_id :: String.t(), priority :: 0..4, opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback set_assignee(issue_id :: String.t(), actor :: String.t() | nil, opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback list_dependencies(issue_id :: String.t(), opts :: keyword()) :: {:ok, [String.t()]} | {:error, ProviderError.t()}
@callback add_dependency(issue_id :: String.t(), depends_on :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback remove_dependency(issue_id :: String.t(), depends_on :: String.t(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
@callback create(attrs :: map(), opts :: keyword()) :: {:ok, Issue.t()} | {:error, ProviderError.t()}
```

### Registry

`ForemanServer.TaskProvider.Registry` is a supervised GenServer that owns registered
providers and exposes `routing_snapshot/0` for capability-aware routing.

---

## Implementation Context

`ForemanServer.Workflow.ImplementationContext` freezes deterministic state at approval time:

- `trd_path`: Normalized project-relative path to the TRD blob
- `bead_id`: For `implement-trd-beads` workflows, the id of the bead that triggered the task (`task.external_id`); rendered as `{{implementation.bead_id}}`; a task without one fails approval (`:bead_id_missing` / `:bead_id_malformed`)
- `trd_path_argument`: JSON-quoted shell argument for the skill
- `project_root`: Absolute project root path
- `source_revision`: Exact git SHA resolved from `git rev-parse HEAD`
- `implementation_key`: `SHA256(project_id <> "\0" <> normalized_trd_path)` — used for single-flight enforcement
- `beads_database_path`: For `implement-trd-beads` workflows, the absolute Beads DB path from the TaskProvider registry

These fields are reserved server-derived values. Operator payload and phase YAML context
cannot override them.

---

## Workflow-door usage and cost (`UsageRecorded`)

`JidoHarnessWorker` records one `UsageRecorded` worker event per run, strictly before
`WorkerExited`, built from `RunMeta` (see the session-id lesson in
`phase-execution-and-pr-mechanics.md`). Failed runs record it too: their tokens were spent.
Nothing is emitted when the provider reported neither tokens nor cost (an all-nil event would
read as "recorded, unknown"). `ForemanServer.Usage` is the single parsing site; the event
carries `provider`, `model`, `project_id`, `task_id`, `role` (`"thread"`), the token fields,
`cost_usd` and `run_status`.

- **Cost is provider-reported only.** Claude puts the dollar cost on the terminal
  `:run_completed` event (`"cost_usd"`), not in `RunResult.usage`; `RunMeta.events_cost_usd`
  carries it. Pi reports `usage.cost.total` on each assistant message from its own price
  table (verified on `pi 1.3.0`, `minimax/MiniMax-M2.7-highspeed`); a model without pricing
  reports `0` there, which cannot be told apart from free. Foreman never computes a price.
- **`null` means unknown, never zero.** `cost_usd: nil` = the provider reported no cost;
  `0.0` = it reported zero. `Usage.merge/2` is nil-preserving (`nil + nil = nil`,
  `nil + n = n`), so a run total's cost is `null` unless some phase reported one.
- **Pi usage is per message.** `Jido.Harness.Run.Worker` merges `:usage` events
  last-write-wins, so `RunResult.usage` holds only the final message. `Usage.from_run/4` sums
  the pi `:usage` events (`RunMeta.usage_events`); Claude's aggregate is already cumulative.
- `Jido.AI.Usage` was evaluated and not adopted: it re-keys to atoms and has no nil-vs-zero
  semantics.
- `ProjectionStore` keeps `workers[worker_id].usage` per worker and `run.usage` as the sum
  over workers (`nil` for historical runs). Both `foreman_run_get` and `foreman_run_status`
  expose it.
- **Cross-run read model (E14).** `ProjectionStore.usage/2` folds `UsageRecorded`, jobsite
  `JobsiteIterationCompleted.usage` (normalised through `Usage.normalize/3` with the jobsite
  `agent` provider/model, so history backfills on replay) and `ReviewRecorded.usage`
  (role `review`, thread = the reviewed subject) into a per-project `Usage.Ledger` of records
  keyed `{thread_kind, thread_id, {:worker, id} | {:iteration, n}}`; a re-applied event
  replaces its record and worker records of a jobsite supersede its iteration records
  (Overwatch-runner jobsites report through `UsageRecorded`, never twice). `Usage.Rollup` is
  the pure fold (totals, by day/thread/model/provider/role, `cost_unknown_events`, 366-day
  retention: older days leave `by_day` and slicing but stay in the unfiltered total).
  `ForemanServer.UsageDTO` is the one wire shape for `GET /api/projects/:id/usage`, the MCP
  `foreman_usage_get` tool and `foreman usage`.
- **Deferral counter.** The Dispatcher records genuine admission refusals
  (`daily_thread_cap_exceeded`, `run_limit_exceeded`, `project_paused`) with the system-only
  `project.note_deferral` command -> `ProjectAdmissionDeferred`, idempotent per
  task/reason/UTC day through its `command_id` (the projection counts distinct tasks), best effort (never raises in the
  subscriber loop). The projection exposes it as `limits.deferred_today` /
  `deferred_by_reason`.
- **Langfuse/Otel cost.** `AgentRuntime` passes the provider-reported cost (`usage.total_cost`)
  or `nil` to `LangfuseTracer.emit_trace/6`, which only builds a trace map and returns
  `{:ok, trace}` (it does not transmit anything itself), and to `OtelSpanEmitter`, whose span
  omits `llm.cost_usd` for an unknown cost. No `0.0` is fabricated (fixed in E0-S4, pinned in
  `otel_span_cost_test.exs` and `agent_runtime_jido_ai_test.exs`).

## Re-homing a session (`project.adopt`)

Event history is immutable, so moving a task/run/jobsite to another project is a
projection re-home, not a rewrite. `project.adopt` runs on the TARGET
`project:<id>` stream and emits `ProjectSubjectAdopted`; `CommandGateway`
enriches the payload from projections (`Projects.Adoption.resolve/1`: owning
task + sibling runs, repo path, activity) so the aggregate stays pure. The
`ProjectionStore` fold rewrites `project_id` on the projected rows and keeps
`adopted_from`; the original events keep their original `project_id`
(`ReviewRecorded` too). `rebuild_project/2` replays only `project:<id>`
streams, so it cannot undo a move. The facade (`Projects.AdoptionService`) then
syncs the on-disk archive manifest idempotently; a crash between the two is
repaired by re-running the same adoption.

---

## Execution Safety Rules

- Before rerunning a task to validate a fix, ensure the fix is durably committed and available on the active branch being tested.
- Treat "implemented" as meaning: relevant tests/build passed and the work has a concrete commit hash on the branch/workspace that will be used for the rerun.
- Do not benchmark or rerun tasks from a dirty or ambiguous controller workspace state.
- If a task reset, branch cleanup, or workspace cleanup is about to happen while important work is only in the working copy, checkpoint it first via commit or patch export.

Task-provider boundary reminder: RunExecutor drives claim/complete/fail;
BootReconciliation drives orphan-reopen.

<!-- bv-agent-instructions-v3 -->

---

