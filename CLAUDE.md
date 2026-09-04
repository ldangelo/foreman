# CLAUDE.md — durable developer architecture conventions

This file records durable, behavior-grounded architecture decisions
for the Foreman repo. Anything that drifts from these rules without
a tracked TRD is a regression. `AGENTS.md` (the agent-context file)
is read-only here — it's a session-level contract for coding
subagents and remains authoritative for that purpose.

## 1. The agent runtime façade is the only public mutation surface

Callers interact with the runtime **only** through
`ForemanServer.AgentRuntime.execute/3` and `register/1` /
`register_adapter/2`. No other module is allowed to:

- start or stop an invocation
- send a `GenServer.call` directly to `AdapterCatalog` from outside
  the façade
- read `Application.get_env(:foreman_server, :agent_runtime, ...)`
  outside of the supervisor, the façade, `FailurePolicy`, or a
  per-adapter config accessor

Adapters do **not** mutate catalog state. The catalog is the durable
registry of which adapters exist; adapter execution lives in short-
lived `Invocation` processes that the catalog never sees.

## 2. Process layering (agent runtime)

```
ForemanServer.Application
  └── ForemanServer.AgentRuntime.Supervisor         (permanent, :one_for_one)
        ├── ForemanServer.AgentRuntime.AdapterCatalog  (GenServer + Registry)
        └── ForemanServer.AgentRuntime.InvocationSupervisor (DynamicSupervisor)
              └── Invocation                       (temporary — one per execute/3 call)
```

- `AdapterCatalog` is **permanent**: registrations are runtime configuration, not request
  state.
- `InvocationSupervisor` is a `DynamicSupervisor` and is **permanent**.
- `Invocation` children are **temporary** — they never restart. A crashed
  invocation is reported to the façade as `{:error, term()}`; sibling
  invocations and the catalog are unaffected (PRD REQ-002).

Overwatch's worker tree layers the same way, with one restart rule that is
easy to get wrong:

```
ForemanServer.Overwatch                              (permanent, :one_for_one)
  ├── ForemanServer.Overwatch.WorkerRegistry
  ├── ForemanServer.Overwatch.Tracker
  ├── ForemanServer.Overwatch.CrashLoopDetector
  └── ForemanServer.Overwatch.WorkerSupervisor       (DynamicSupervisor)
        └── LaunchWorker                             (transient — one per phase)
```

- `LaunchWorker` children are **transient**, and `LaunchWorker`'s own exit
  reason is the relaunch decision: `:normal`/`:shutdown` from its worker
  (phase finished and reported, or deliberate teardown) exits `:normal` and
  ends the child, while any other worker exit reason becomes
  `{:worker_crashed, reason}` so the child relaunches and
  `CrashLoopDetector` counts the restart.
- Do **not** make them `:permanent`. `:permanent` cannot express "restart on
  crash only", so the supervisor relaunched finished phases too, starting a
  second agent for work that was already over. `RunExecutor`'s detached
  `WorkerSupervisor.stop_worker/2` is cleanup, not a guard — it is a race,
  and in run-de055c18749db5e9c702d24950268cf9 it lost by 56ms and the leaked
  agent ran 8m42s past `RunFailed`, overwriting the run's phase artifact.

## 3. Errors flow one way

Public `:execute/3` always returns one of:

```elixir
{:ok, String.t()}
| {:error, :no_available_backend | :backend_not_found | :backend_unavailable | :timeout}
| {:error, {:non_zero_exit, non_neg_integer()}}
| {:error, :all_backends_failed, %{attempts: [attempt_result()]}}
| {:error, term()}
```

The successful branch **never** contains a backend name. Backend
identity is recorded only in telemetry metadata. Adapter-private
metadata (e.g. raw output tokens) does not leak into the public
result; the adapter may produce it but the invocation returns only
the public text.

## 4. The `BackendAdapter` behaviour

```elixir
@callback name() :: atom()
@callback capabilities() :: %{required(:type) => atom(),
                              required(:strengths) => [...],
                              required(:weaknesses) => [...],
                              required(:supported_contexts) => [...],
                              optional(:cost_per_call) => number(),
                              optional(:typical_latency_ms) => non_neg_integer()}
@callback available?() :: boolean()
@callback execute(%{prompt: String.t(), context: map()}, keyword()) ::
            {:ok, String.t(), map()} | {:error, term()}
```

- `capabilities/0` is validated by `ForemanServer.AgentRuntime.BackendAdapter.validate_capabilities/1`
  at registration time. A missing required field or wrong type returns
  `{:error, reason}` and **nothing is inserted** into the catalog.
- `available?/0` is consulted on every `execute/3` call, not at
  registration time. An unavailable adapter is silently skipped in
  automatic/policy modes but produces `{:error, :backend_unavailable}`
  in manual mode.
- `execute/2` runs inside the `Invocation` process. Adapters are
  responsible for the timeout clock, for any port/process cleanup, and
  for returning a canonical `{:ok, text, metadata}` or
  `{:error, reason}` shape. The invocation adapts that shape into the
  public result types above.

## 5. `execute/3` strategies

```elixir
ForemanServer.AgentRuntime.execute(prompt, context,
  strategy: :manual,        # | :automatic | :policy
  backend: :my_backend,      # required when strategy is :manual
  task_type: :code_review,   # required when strategy is :automatic or :policy
  policy_module: SomeMod,    # only for :policy
  timeout_ms: 60_000,        # per-call override; falls back to FailurePolicy
  fallback: true,            # per-call override; falls back to FailurePolicy
  max_attempts: 3,           # per-call override; falls back to FailurePolicy
  fail_on_unavailable: true # if true (default), no_available_backend is reported
                            # even when fallback is on but no backend is available
)
```

- `:manual` requires `backend`; missing registration returns
  `:backend_not_found`; unavailable registration returns
  `:backend_unavailable`. Manual mode **never** substitutes another
  backend.
- `:automatic` filters `supported_contexts` → `available?/0`, then
  sorts by lower `cost_per_call` (missing values sort last), lower
  `typical_latency_ms` (missing values sort last), and earliest
  registration order. **No random selection.**
- `:policy` calls `policy_module.route(task_type, capabilities)`.
  A non-registered result returns `{:error, :backend_not_found}`.
  An unavailable result is skipped if the resolved failure policy
  has `fallback: true`.

## 5.1 Jido Harness provider and model selection

`ForemanServer.AgentRuntime.JidoHarness` is the supported-provider
source of truth for the Jido Harness adapter. It currently accepts
`:pi`, `:claude`, and `:litellm`; string provider keys from decoded
workflow context are normalized at this boundary.

Workflow phase `models.default` becomes `context.model`, and
`JidoHarnessAdapter` forwards it as the harness `:model` option for the
selected provider. Provider selection is explicit (`context.provider`);
Foreman must not infer a provider from the model string.

## 6. `FailurePolicy.resolve/2` precedence

Resolved keys: `:fail_fast`, `:fallback`, `:max_attempts`, `:timeout_ms`.

`fail_fast` is always `true` in the resolved map (the operator cannot
override it; the literal matches the TRD default verbatim).

Resolution order, high → low:

1. Per-call `opts` — **only present keys override.** `RunExecutor` passes
   `timeout_ms` here when a workflow phase declares `timeout_minutes:`.
2. App config: `config :foreman_server, :agent_runtime, failure_policies: %{task_type => %{...}}`.
3. Built-in defaults:
   `%{fail_fast: true, fallback: false, max_attempts: 1, timeout_ms: 60_000}`.

Special rule (TRD-007 AC-3): if the resolved `:fallback` is `true`
and **no layer** supplies `:max_attempts`, then `:max_attempts` is `2`.

## 7. Telemetry contract

A **single** completion event is emitted per `execute/3` call, on
`[:foreman, :agent_runtime, :invocation, :complete]`. The façade owns
this emission (early-exit branches call `emit_early_exit_completion/3`;
the invocation's terminal branch emits the normal-completion event).
Duplicate emissions are a contract violation.

Measurements:

```elixir
%{duration_us: non_neg_integer(), attempt_count: non_neg_integer()}
```

Metadata (a stable whitelist — this is the **only** shape emitted):

```elixir
%{
  status: :ok | :no_available_backend | :backend_not_found
        | :backend_unavailable | :direct_error | :all_backends_failed
        | :policy_module_raised | :invocation_start_failed
        | :timeout | {:non_zero_exit, non_neg_integer()},
  task_type: atom() | nil,
  attempted_backends: [atom()],
  final_backend: atom() | nil,
  successful_backend: atom() | nil,
  adapter_metadata: map()   # adapter-private; never the prompt
}
```

Privacy-safe by construction: every metadata key is constructed by a
narrow clause that pattern-matches the result shape and **projects**
the whitelist — adapters cannot accidentally leak prompt text,
secrets, or full output bodies through metadata. Adapter `metadata`
from a successful adapter is forwarded as `:adapter_metadata`; this
is the only adapter contribution to the completion event.

## 8. Configuration keys (operator-visible)

App config read by the runtime:

| Key | Where read | Default |
|---|---|---|
| `:foreman_server, :agent_runtime, :enabled` | `Application.start/2` child wiring | `false` (set to `true` in `config.exs`) |
| `:foreman_server, :agent_runtime, :adapters` | `AgentRuntime.Supervisor.init/1` | `[]` |
| `:foreman_server, :agent_runtime, :failure_policies` | `FailurePolicy.resolve/2` | `%{}` |
| `:foreman_server, :agent_runtime, :default_timeout_ms` | `FailurePolicy.resolve/2` | `60_000` |
| `:foreman_server, ForemanServer.AgentRuntime.Adapters.PiAdapter, :executable` | `PiAdapter.execute/2` | `"pi"` (resolved via `System.find_executable/1`) |
| `:foreman_server, ForemanServer.AgentRuntime.Adapters.PiAdapter, :timeout_ms` | `PiAdapter.execute/2` | `60_000` |

The per-`task_type` policy map uses the same shape as the resolved
`FailurePolicy.t/0` minus `:fail_fast`:

```elixir
config :foreman_server, :agent_runtime,
  failure_policies: %{
    code_review: %{fallback: true},
    long_running: %{timeout_ms: 5 * 60_000, max_attempts: 3, fallback: true}
  }
```

Adding a key not listed above is treated as a feature request, not
a bug; do not invent behavior for undocumented keys.

## 9. Adapter extension checklist (developer workflow)

1. `defmodule MyApp.MyAdapter do` with `use ForemanServer.AgentRuntime.BackendAdapter`
   (or implement the four callbacks by hand).
2. Implement `name/0`, `capabilities/0`, `available?/0`, `execute/2`.
3. Register via config (`adapters: [...]`) or at boot:
   `ForemanServer.AgentRuntime.register(MyAdapter)`.
4. Validation runs on every registration; fix any
   `{:error, reason}` reply before considering the adapter wired.
5. ExUnit coverage:
   - adapter returns `{:ok, text, %{}}` for the happy path,
   - adapter returns `{:error, reason}` for the canonical failure,
   - `available?/0` is `false` when the underlying resource is gone,
   - the public `execute/3` result contains **no** backend identifier.

## 10. Things that are deliberately not in this slice

- No streaming. Each `execute/3` is one round-trip; partial progress
  is not surfaced.
- No retry of the entire execution across crashes. The invocation
  process owns attempt history; the OS process backing a crashed
  adapter may leak a temp file.
- No queueing for unavailable adapters. An empty / unavailable
  catalog returns `:no_available_backend` immediately.
- No remote backend in this slice. `PiAdapter` is local only.

These are tracked in the TRD-2026-6af02293 documentation under
*Open Issues / Future Work*. Any code that introduces them inline
without a TRD is out of scope.

## 11. Workflow catalog is the only manifest source (Go/Elixir CQRS slice)

`ForemanServer.Workflow.Catalog` is the supervised GenServer that owns
every parsed workflow manifest and prompt body in memory and keeps
them in sync with the on-disk root (`~/.foreman/workflows`,
hardcoded by `AssetCatalog.default/0`). Phase specs normalize `commit:` and
`stack_pr:` as boolean phase fields and `timeout_minutes:` (or camelCase `timeoutMinutes:`) as an optional
positive-integer phase execution timeout in minutes. `stack_pr: true` records a
phase PR from the single run branch to the recorded run base branch and keeps it
separate from the final run `pr_url`.

- **Single owner of manifests.** `Approval.resolve_workflow_snapshot/2`
  (the public `Approval.prepare/2` path) and the private
  `RunExecutor.read_phase_prompt/2` read through the catalog.
  No module reads a workflow manifest or prompt file directly;
  the catalog is the only path.
- **Auto-install is gated.** `init/1` calls
  `ForemanServer.WorkflowTemplate.Installer` only when the root
  contains no `*.yaml` manifests. A populated `prompts/` directory
  does **not** suppress the install; the installer uses
  `File.cp/2`/`File.write/2` and will overwrite any same-named
  prompt already on disk. Keep custom templates under their own
  filenames.
- **Synchronous load.** Every manifest is parsed via
  `ForemanServer.Workflow.Interpreter.load/1` and every prompt via
  `File.read/1` during `init/1` so the first command after boot
  finds the catalog ready.
- **Hot reload by polling.** A periodic timer (default 2 s,
  override via `Application.put_env(:foreman_server,
  :workflow_catalog_poll_ms, ms)`) re-hashes every entry and
  replaces any whose content or mtime changed; vanished files are
  removed. `:fs` is **not** used; this slice does not depend on
  the `FileSystem` package.
- **Test isolation.** `Catalog.server/0` reads the
  `:workflow_catalog` app env so tests can redirect to a scoped
  instance via `Application.put_env(:foreman_server,
  :workflow_catalog, server_name)` without tearing down the
  app-managed catalog.

Telemetry: `[:foreman_server, :workflow, :installed]`,
`[:foreman_server, :workflow, :manifest, :loaded | :reload, :ok |
:reload, :error | :removed]`,
`[:foreman_server, :workflow, :prompt, :loaded | :reload, :ok |
:reload, :error | :removed]`.

Operator-facing CLI: `foreman workflow install --target PATH [--source PATH | --remote URL]`
(see `docs/cli-reference.md`). The CLI is a thin shell around the
HTTP admin endpoint and is **not** an alternate write path to the
event store; it only materialises assets on disk.

## 12. Foreman-managed worktree contract for implement-trd workflows (Go/Elixir CQRS slice)

Foreman bundles two workflow manifests at
`packages/foreman_server/priv/defaults/workflows/`:
`implement-trd.yaml` and `implement-trd-beads.yaml`. Both declare
the worktree schema, register with
`ForemanServer.WorkflowTemplate.Installer` (`@template_names`), and
are deployed by `foreman init --force`. The CLI selects them via
`--workflow-type implement-trd` or `--workflow-type implement-trd-beads`
(see `docs/cli-reference.md` for the full flag set).

Strict approval rendering materializes the `command` field and the
`worktree.base` field so the human review surfaces the exact slash
command and base ref Foreman will execute. Branch placeholders
(`{task_id}`, `{run_id}`) and the path placeholder (`{run_id}`) remain
runtime-resolved; `{phase}` is retained only as literal text, not substituted.

The phase runner (`ForemanServer.Workflow.RunExecutor`) auto-injects
the following env vars when the worktree is enabled:
`FOREMAN_WORKTREE`, `FOREMAN_RUN_ID`, `FOREMAN_WORKTREE_PATH`,
`FOREMAN_EXPECTED_BRANCH`, `FOREMAN_SOURCE_REVISION`, and
`FOREMAN_IMPLEMENTATION_KEY`. The Beads-backed flow additionally
receives `BEADS_DB` and `TRD_SCOPE` when the planning context
provides them. `FOREMAN_EXPECTED_BASE` is **not** injected; the base
is resolved lazily at completion time to honor pushes that landed
during the phase.

`RunExecutor.init/1` parses the persisted `workflow_snapshot` via
`extract_phase_specs/1`, which uses the dual-key pattern
`Map.get(snapshot, :phases) || Map.get(snapshot, "phases")` so the
persisted (JSON-decoded) projection shape is honored. The
renderer in `CommandGateway.enrich_approval_via_workflow/2` writes
back the canonical string-keyed form so the EventStore-bound
`TaskApproved` payload has exactly one entry per field and the
JSON round-trip is lossless.

### Contract checklist for contributors (worktree/TRD slice)

- **Task vs. workflow.** Provider task type is independent of
  implementation workflow. `--workflow-type` selects which bundled
  manifest Foreman resolves at approval. Approval precedence is
  `workflow_type || task_type || default_task_type`; absent fields
  preserve existing behavior.
- **Tracked TRD.** `--trd-path` must be a tracked regular blob in
  the registered project at the frozen source revision.
  `ImplementationContext.build/1` rejects untracked, working-copy,
  directory, symlink, and traversal cases; the frozen relative path
  and SHA persist for idempotent re-approval.
- **Worktree ownership.** Foreman exclusively creates, pins, and
  cleans the worktree at `~/.foreman/worktrees/<project_id>/<run_id>/<path>`.
  Skills under `--foreman` must verify the trusted
  cwd/branch/revision markers and must not create, switch, append,
  or stack branches. There is no skill-owned worktree fallback.
- **Same-TRD single-flight.** `implementation_key = SHA256(project_id
  <> "\0" <> normalized_trd_path)` is reserved through
  `ProjectRunReserved`. Concurrent `run.start` for the same key is
  rejected with `{:implementation_already_active, key, run_id}`
  before any worktree side effect. The key is server-derived and
  cannot be overridden by operator payload or phase YAML context.
- **Beads scope.** For `implement-trd-beads`, freeze
  `task_provider.config.database_path` (from the TaskProvider
  Registry, not cwd discovery; Go CLI project create/update requires
  `--task-provider-database-path` when `--task-provider=beads`) and
  `TRD_SCOPE = <trd-slug>-<first-12-of-key>`
  at approval. Every `br`/`bv` invocation passes `BEADS_DB` and
  `TRD_SCOPE` explicitly. Scaffolds are prefixed `[trd:<TRD_SCOPE>]`.
- **Clean-vs-dirty cleanup.** Clean worktrees are removed on
  terminal phases; dirty worktrees are preserved with reason
  `:dirty` / `:active_workers` / `:clean_failed` /
  `:resolve_dispatch_failed` on
  `[:foreman_server, :vcs, :worktree, :orphan_preserved]`. Recovery
  never force-deletes.

## 13. Task-provider boundary reminder (Go/Elixir CQRS slice)

RunExecutor drives claim/complete/fail. Workflow.BootReconciliation
drives orphan-reopen. `set_priority` and `add_dependency` stay at the
adapter boundary until a separate operator surface TRD introduces them.

## 14. Beads sync invariants (Go/Elixir CQRS slice)

Atomic `task.create` and bidirectional Beads sync are governed by
these invariants. Drift without a tracked TRD is a regression.

- **Atomic `task.create`.** `Task.create` flows through the `Task`
  aggregate in a four-stage pipeline (`actor.ex`: `do_dispatch/4`):
  (1) `handle_command/2` produces the stage-1 event spec;
  (2) `resolve_enriched_event_spec/3` invokes the project's configured
  `:create` provider (`TaskProvider.Registry.route(:create, ...)` →
  `provider.create/2`) to mint a Bead **before** the append;
  (3) the actor re-decides `handle_command/2` with the Bead ID
  populated as `payload.external_id` on the event spec;
  (4) `append_and_commit/7` performs the append/ack/commit.
  **Provider failure aborts the command entirely**: a `{:error, _}`
  from `provider.create/2` returns `{:error, reason, state}` with no
  append, no event, and no compensation (no Bead was minted to close).
  **Conflict / re-decision failures compensate the Bead**: on the
  bounded retry path, `compensate_for_conflict/3` closes the Bead via
  `BeadsAdapter.complete/3` with the canonical `transition_comment`
  so a successful stage 2 does not strand. The cache entry in
  `state.in_flight_beads` is the single source of truth for "Bead
  minted but not committed"; clearing it after compensation prevents
  double-close on a subsequent retry. (Other append-failure modes
  outside the conflict-retry path are not characterized here.)
- **`external_id` surface contract.** The successful `task.create`
  HTTP response (HTTP 201 with `status: "accepted"`,
  `result: %{events: 1}`) does **not** carry `external_id` —
  `CommandController.serialize/1` returns `%{events: 1}` for
  `{:ok, _events}` and does not enrich the response with the
  persisted event's fields. Operators retrieve the bead linkage by
  reading the task projection (`GET /api/tasks/:id`,
  surfaced via `foreman task get`), whose `external_id` field is
  populated on the persisted `TaskCreated` event when the
  project's `task_provider` capabilities advertised `:create`.
  Provider failure aborts the command entirely (no event, no
  successful response, no `external_id` surface).

- **Operator-issued ≠ no-Bead.** A `task.create` issued by the
  operator on a project with a configured `:create` provider still
  gets an `external_id`. The presence/absence of `external_id` means
  "Bead linked" vs "Bead not linked", **not** "operator-issued" vs
  "system-issued". The MCP `foreman_task_create` helper requires
`description` for `FOREMAN_TASK_DESCRIPTION`, passes `prompt` separately for
`:prompt`-action phases, and defaults `auto_approve: true`.
- **Beads → Foreman (inbound) is opt-in.** The
  `BeadsWatcherSupervisor` is added to `ForemanServer.Application`
  only when `config :foreman_server, :start_beads_watcher?, true`.
  The watcher dispatches `task.create` for each new Bead it sees in
  the project's JSONL; that `task.create` re-enters the same Actor
  hook path, so a Bead originated by the watcher does **not** cause
  another Bead to be minted (provider skips when the Bead already
  exists).
- **Orphan janitor is opt-in.** `BeadsOrphanJanitorSupervisor` is
  added only when `config :foreman_server, :start_beads_orphan_janitor?,
  true`. The janitor closes stranded issuance (Bead minted but no
  Foreman task landed within the grace window) and stranded execution
  (Foreman task terminal but Bead never closed by `RunExecutor`). Both
  flags are required for production: watcher-only strands execution,
  janitor-only strands inbound issuance.
- **Adapter boundary holds.** `set_priority` and `add_dependency`
  remain adapter callbacks. No operator surface promotes them into
  Foreman commands in this slice.
- **Doctor surface is honest about current scope** — about its *fields*, not
  its existence. `foreman doctor` is not a command: the Go CLI dispatches only
  `project`, `commands`, `task`, `run`, `workflow`, `init`
  (`packages/foreman_cli/cmd/foreman/main.go`), which `README.md:70` and
  `docs/user-guide.md:595` already state. The field list below describes what
  the surface would report, and matches the server-side shape; treat it as a
  spec, not as an operator command.
  `foreman doctor task_provider` reports the fields it actually
  emits per project: `project_id`, `healthy`, `provider_id`,
  `contract_version`, `br_version`, `capabilities`, `sample_ready`,
  `schema_validation_failures`, `janitor_enabled`, `janitor_running`,
  `orphan_backlog`, and (on the unhappy branch) `error`. The
  janitor fields are a CQRS read of the cached snapshot maintained
  by `BeadsOrphanJanitor`'s own scan loop; the doctor MUST NOT
  invoke `BeadsOrphanJanitor.run_scan/2` itself. Operators needing
  finer-grained runtime visibility (per-scan event streams,
  supervisor lifecycle transitions) should rely on the
  `[:foreman_server, :task_provider, :beads, ...]` telemetry events.

## 15. Per-DB Beads lease (Go/Elixir CQRS slice)

SQLite's single-writer protocol cannot tolerate concurrent `br`/`bv`
writers or writers running alongside `bv --robot-plan`. The
`ForemanServer.Aggregates.BeadsDbLease` aggregate is an event-sourced
lock keyed by the configured absolute Beads DB path passed at acquire
time, giving process-local serialization through the Actor mailbox
while surviving Foreman restarts via persisted events. Different DBs
and direct (`foreman run`) workflows remain parallel. Callers must
pass the same absolute path on every dispatch — symlink aliasing
(e.g. `/tmp/...` vs `/private/tmp/...`) is NOT collapsed and will
register separate lease streams.

- **Acquire-or-enqueue.** `lease.acquire` is atomic: if the DB is
  free, the run becomes the holder; if held, the run is enqueued as a
  waiter and admission returns `:queued`.
- **Release-with-promotion.** When the holder releases with waiters,
  the aggregate emits a single `BeadsDbLeaseTransferred` event that
  releases the old holder and promotes the head waiter, so cancellation
  cannot race with promotion. The `Dispatcher` subscribes to this
  event and re-enters `RunAdmission.start/2` for the promoted run.
- **Terminal fan-out.** The `Dispatcher` dispatches `lease.release`
  and `lease.remove_waiter` on every terminal run event
  (`RunCancelled`, `RunDeleted`, `RunFlaggedStuck`, `RunCompleted`, `RunFailed`,
  `RunBlocked`). `RunBlocked` is terminal for lease cleanup: a blocked
  run must release its Beads-DB lease so queued peers can be promoted.
- **Fail-closed gating.** `RunAdmission.start/3` reads the lease
  decision before starting the run supervisor. Any uncertainty
  (acquire error, atom state of `:unknown` or `:unexpected`) returns
  `{:error, ...}` and skips dispatch. A `:queued` decision returns
  without starting the supervisor; the dispatcher picks the run up
  again on `BeadsDbLeaseTransferred`.
- **Compensation.** `lease.release` on admission failure is only emitted
  for definitively non-retryable rejections (`{:missing_or_invalid, …}`,
  `{:implementation_already_active, …}`, `{:command_rejected, …}`).
  Compensating transient errors would break retry semantics.
- **Scope limitation (operator responsibility).** The lease serializes
  only admission through Foreman. External `br` writers and
  `bv --robot-plan` invocations launched outside Foreman (e.g. from a
  human shell or unrelated automation) are NOT gated by this lease.
  If you bypass Foreman and write to the same Beads DB concurrently
  with a held lease, SQLite's single-writer model will still observe
  concurrent writers. Operators must observe single-writer discipline
  themselves. The lease exists to prevent two Foreman-dispatched runs
  from racing on the same DB, not to mediate file-system access against
  unrelated processes. The contract test
  `test/foreman_server/workflow/br_bv_lease_concurrency_test.exs`
  verifies the admission contract; cross-process discipline against
  external writers is a separate, operator-owned concern.

## 19. Durable worker run logs and MCP run status

`foreman_run_status` is a bounded DTO built from `ProjectionStore.run/1` and
`ProjectionStore.phases_for_run/1`; do not rebuild it from logs or raw event
streams, and keep `foreman_run_get`'s full projection shape distinct.

`foreman_run_get_logs` is backed by `ProjectionStore`, not console `Logger`
output or ad hoc files. Production worker output must enter the system only as
`WorkerProtocol.emit(:worker_stdout | :worker_stderr, ...)` events on
`worker:<run_id>:<worker_id>` streams. The projection returns empty success for
known runs with no captured output and `:run_not_found` for unknown runs; never
substitute `{:ok, []}` for an unknown run. There is deliberately no
store-unavailable failure — the projection is the `ProjectionStore` GenServer's
own state, so for a known run the read cannot fail, and declaring failures that
cannot occur misdescribes the contract. Redact and control-character-normalize
output before event persistence.

**stdout and stderr arrive on different `Jido.Harness` events, and this is the
one thing to check when a channel comes back empty.** stdout text rides
`:output_text_delta` / `:output_text_final` / `:command_output_delta` with a
string-keyed `%{"text" => _}` payload. stderr does NOT: the harness turns
`ProcessEvent{type: :stderr}` into `Event{type: :provider_event}` carrying
`%{"stream" => "stderr", "data" => _}` (`adapters/cli_stream.ex:37-38`,
`session/transports/pi_rpc.ex:138-140`). Selecting only the three text types and
then looking for a `"stream"` key on them — which is never there — made
`WorkerStderr` unreachable while every layer above still advertised
stdout/stderr capture. `jido_harness_worker_log_capture_test.exs` pins both
shapes against the dep source so an upgrade cannot silently re-empty the
channel.

**Retention is bounded on two axes, and both are load-bearing.** Entry count
(5,000/run) does not bound memory, because a log line has no intrinsic size
limit and a run may have many workers; bytes (1 MiB/run) does. This is a bound
on the resident READ MODEL and is distinct from `WorkerLogPolicy`'s bound on how
many events are durably WRITTEN — different resources, not a duplicated
boundary. Every eviction is accounted in `omitted_entries` / `omitted_bytes`, so
a truncated read can never present itself as complete.

## Phase stall detection

`stall_detection` is explicit phase metadata, never inferred from phase names. Normalize it through `ForemanServer.Workflow.StallPolicy`; valid scopes are agent/no-output and messaging/no-progress. `RunExecutor` copies normalized policy onto `phase.start`/`PhaseStarted`, `ProjectionStore.stall_candidates/1` is the bounded detector read, and `ForemanServer.StallDetector` persists stalls through `run.report_stall` only. Do not write projection state directly from the detector. Worker heartbeats do not advance phase output activity; stdout/stderr, assistant messages, tool completions, worker start/exit, and phase lifecycle do.
