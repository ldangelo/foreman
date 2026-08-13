defmodule ForemanServer.AgentRuntime.InvocationSupervisor do
  @moduledoc """
  DynamicSupervisor for agent execution invocations.

  Each invocation is a short-lived GenServer that executes a single
  backend adapter call and returns the result. Children use
  `restart: :temporary` — they are never restarted after normal
  completion or handled crashes.

  Configuration mirrors `Overwatch.WorkerSupervisor`:
  - strategy: `:one_for_one`
  - max_restarts: 1_000
  - max_seconds: 1
  """
  use DynamicSupervisor

  alias ForemanServer.AgentRuntime.Invocation
  alias ForemanServer.AgentRuntime.BackendAdapter

  @type candidate :: {BackendAdapter.adapter(), boolean()}

  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, [], name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 1_000,
      max_seconds: 1
    )
  end

  @doc """
  Start a new invocation process with a single adapter (legacy API).

  This overload is provided for backward compatibility. For new code, use
  `start_invocation/5` with candidates and policy.
  """
  @spec start_invocation(module(), map(), pid(), GenServer.server()) ::
          {:ok, pid(), reference()} | DynamicSupervisor.on_start_child()
  def start_invocation(adapter_module, request, caller, supervisor)
      when is_atom(adapter_module) do
    # Convert legacy single-adapter call to new format
    candidates = [{adapter_module, true}]
    policy = %{fail_fast: true, fallback: false, max_attempts: 1, timeout_ms: 60_000}
    start_invocation_impl(candidates, policy, request, caller, supervisor, nil, %{})
  end

  @doc """
  Start a new invocation process.

  The caller provides:
  - `candidates` — ordered list of `{adapter_module, available?}` tuples
  - `policy` — resolved failure policy map with :fallback, :max_attempts, :timeout_ms
  - `request` — the execution request map with :prompt and :context
  - `caller` — the PID to receive the result
  - `task_type` — the `:task_type` keyword for telemetry metadata (atom or nil)
  - `supervisor` — the supervisor to start the invocation under (optional, defaults to __MODULE__)
  - `env` — adapter-private trusted env map (`BackendAdapter.env_map()`) forwarded
    to `adapter.execute/2` via the `:env` option. Defaults to `%{}` (no injection).
    The supervisor MUST NOT inspect, log, or include this map in telemetry.

  Returns `{:ok, invocation_pid, invocation_ref}`.
  """
  @spec start_invocation([candidate()], map(), map(), pid(), atom() | nil, GenServer.server()) ::
          {:ok, pid(), reference()} | DynamicSupervisor.on_start_child()
  def start_invocation(candidates, policy, request, caller, task_type, supervisor)
      when is_list(candidates) do
    start_invocation_impl(candidates, policy, request, caller, supervisor, task_type, %{})
  end

  # Default supervisor version
  def start_invocation(candidates, policy, request, caller, task_type) do
    start_invocation_impl(candidates, policy, request, caller, __MODULE__, task_type, %{})
  end

  @doc """
  Start a new invocation process with an adapter-private env map.

  This entry point is for callers (typically `AgentRuntime.execute/3`) that
  inject a trusted env map into the child's `Port.open` invocation. The map
  is forwarded verbatim to `adapter.execute/2` and is intentionally not
  inspected here — see `BackendAdapter.env_map/0` for the typedoc.
  """
  @spec start_invocation(
          [candidate()],
          map(),
          map(),
          pid(),
          atom() | nil,
          GenServer.server(),
          BackendAdapter.env_map()
        ) :: {:ok, pid(), reference()} | DynamicSupervisor.on_start_child()
  def start_invocation(candidates, policy, request, caller, task_type, supervisor, env)
      when is_list(candidates) and is_map(env) do
    start_invocation_impl(candidates, policy, request, caller, supervisor, task_type, env)
  end

  # Note: there is intentionally no /6 `start_invocation(... env)` overload.
  # The pre-existing /6 takes `supervisor` as its 6th arg, so an env map
  # would be silently routed as a supervisor. Callers that need env must
  # use the explicit /7 form below.

  # Implementation
  defp start_invocation_impl(candidates, policy, request, caller, supervisor, task_type, env) do
    ref = make_ref()
    spec = {Invocation, {candidates, policy, request, caller, ref, task_type, env}}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> {:ok, pid, ref}
      other -> other
    end
  end
end
