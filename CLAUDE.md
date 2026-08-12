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

## 6. `FailurePolicy.resolve/2` precedence

Resolved keys: `:fail_fast`, `:fallback`, `:max_attempts`, `:timeout_ms`.

`fail_fast` is always `true` in the resolved map (the operator cannot
override it; the literal matches the TRD default verbatim).

Resolution order, high → low:

1. Per-call `opts` — **only present keys override.**
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
hardcoded by `AssetCatalog.default/0`).

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


## 12. Task-provider boundary reminder (Go/Elixir CQRS slice)

RunExecutor drives claim/complete/fail. Workflow.BootReconciliation
drives orphan-reopen. `set_priority` and `add_dependency` stay at the
adapter boundary until a separate operator surface TRD introduces them.

## 13. Beads sync invariants (Go/Elixir CQRS slice)

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
  "system-issued".
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
- **Doctor surface is honest about current scope.**
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
