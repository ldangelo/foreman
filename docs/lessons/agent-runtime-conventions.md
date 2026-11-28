# Agent runtime conventions (§1–§10)

> Moved verbatim from `CLAUDE.md`. Section numbers are unchanged; `CLAUDE.md` names the file holding each `§N`, so a reference to a section that is not in this file resolves there.

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
- A run that stops is cleaned up from the Overwatch registry, not from
  `RunControl`: the executor's `terminate/2` clears `RunControl`, so a failed
  run's live worker has nothing left to cancel. `Workflow.Dispatcher` calls
  `RunControl.cancel_agent/1`, gives the run's workers a wind-down
  (`@worker_wind_down_ms`) to finish by themselves, then
  `WorkerSupervisor.stop_run_workers/1` stops what is left, provided the
  projection still shows the run stopped. Stopping a `LaunchWorker` stops its
  worker (`LaunchWorker.terminate/2`) and the worker's `terminate/2` cancels its
  harness run (`Driver.stop/2`), so no agent outlives its worker.
  `Overwatch.start_phase/2` refuses a second worker for a run that has one alive
  (`{:worker_already_running, run_id}`).

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
  registration time. The catalog never runs the probe inside its own process
  (it can spawn a provider CLI): `AdapterCatalog.available?/2` and
  `routing_snapshot/1` evaluate it in the calling process, so a slow probe
  cannot block registration or application boot (foreman-duhcq). An unavailable adapter is silently skipped in
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
`:pi` and `:claude` (`@supported_providers`); string provider keys from
decoded workflow context are normalized at this boundary. A LiteLLM
proxy is a model dispatcher reached through one of those providers,
not a provider itself — `:litellm` is not a valid `provider:` value.

Workflow phase `models.default` becomes `context.model`, and
`JidoHarnessAdapter` forwards it as the harness `:model` option for the
selected provider. Provider selection is explicit (`context.provider`);
Foreman must not infer a provider from the model string.

`Workflow.ModelResolution` decides that model once per phase and names the rule:
`:phase_declared` (the phase's `models.default`) > `:project_thread_model` (only for
a phase that declares none) > `:provider_default` (no model passed). `RunExecutor`
logs it per phase launch (`operation: "run_executor.phase_model"`), and every
`PreflightFailure` carries it as `model_source`; both are log/run-state only, with no
event or persisted-shape change. See `docs/user-guide.md` §7.2 for the operator view
and the recovery path.

## 6. `FailurePolicy.resolve/2` precedence

Resolved keys: `:fail_fast`, `:fallback`, `:max_attempts`, `:timeout_ms`.

`fail_fast` is always `true` in the resolved map (the operator cannot
override it; the literal matches the TRD default verbatim).

Resolution order, high → low:

1. Per-call `opts` — **only present keys override.** `RunExecutor` passes
   `timeout_ms` here when a workflow phase declares `timeout_minutes:`.
2. Per-task app config: `config :foreman_server, :agent_runtime, failure_policies: %{task_type => %{...}}`.
3. App config default: `config :foreman_server, :agent_runtime, default_timeout_ms: ...`.
4. Built-in defaults:
   `%{fail_fast: true, fallback: false, max_attempts: 1, timeout_ms: :infinity}`
   (unattended-run-control: dev/prod config sets no `default_timeout_ms`, so
   phases have no default wall-clock deadline; `timeout_minutes: 0` on a
   phase, or omitting it, both resolve to `:infinity` unless an explicit app
   config policy/default is present — declare a positive `timeout_minutes:` to
   opt a phase back into a deadline).

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

For the `agent_runtime` completion event, privacy-safe by construction: every metadata key is constructed by a
narrow clause that pattern-matches the result shape and **projects**
the whitelist — adapters cannot accidentally leak prompt text,
secrets, or full output bodies through metadata. Adapter `metadata`
from a successful adapter is forwarded as `:adapter_metadata`; this
is the only adapter contribution to the completion event.

Span policy (separate from that event): coordinator-turn and workflow-phase
spans (`foreman.coordinator.turn`, `foreman.workflow.phase`) carry redacted,
8000-char-capped message text as `gen_ai.input.messages` /
`gen_ai.output.messages` and go to every trace backend behind the collector
(Langfuse and Lens). Each coordinator turn also has a child `chat <model>` span
(`OtelSpanEmitter.with_chat_span/4`, the model call Lens renders as a request)
that carries the same messages and the token usage (`gen_ai.usage.*`, on the
child only so it is counted once); a phase has only its root span. A raised
exception marks a span errored with its type only, never its message. The
collector `debug` exporter is kept at `basic`, so none of that text is written
to the container log.

## 8. Configuration keys (operator-visible)

App config read by the runtime:

| Key | Where read | Default |
|---|---|---|
| `:foreman_server, :agent_runtime, :enabled` | `Application.start/2` child wiring | `false` (set to `true` in `config.exs`) |
| `:foreman_server, :agent_runtime, :adapters` | `AgentRuntime.Supervisor.init/1` | `[]` |
| `:foreman_server, :agent_runtime, :failure_policies` | `FailurePolicy.resolve/2` | `%{}` |
| `:foreman_server, :agent_runtime, :default_timeout_ms` | `FailurePolicy.resolve/2` | `:infinity` |

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
- No remote backend in this slice. `JidoHarnessAdapter` runs provider CLIs locally.

These are tracked in the TRD-2026-6af02293 documentation under
*Open Issues / Future Work*. Any code that introduces them inline
without a TRD is out of scope.
