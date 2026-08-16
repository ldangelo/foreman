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
  @type invocation_id :: reference()

  # Module-level key for tracking the registry name of the most recently
  # started supervisor instance. Tests start supervisors with unique names
  # per test; production has a single named supervisor. Either way, only
  # one is live at a time, so a single persistent_term key is sufficient
  # for `terminate_invocation/1` to discover its registry.
  @registry_key {__MODULE__, :registry_name}

  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    registry_name = :"#{name}.InvocationRegistry"

    # The Registry is a singleton per supervisor name. Multiple supervisors
    # across the test suite (or a supervisor restart in production) reuse
    # the same Registry process; we tolerate the `already_started` return
    # so duplicate `init/1` calls do not crash.
    case Registry.start_link(keys: :unique, name: registry_name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Publish the registry name so `terminate_invocation/1` can find it from
    # any process. The most recent `start_link/1` wins; this is correct in
    # production (one global supervisor) and in tests (one live supervisor
    # at a time, named uniquely per test).
    :persistent_term.put(@registry_key, registry_name)

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 1_000,
      max_seconds: 1
    )
  end

  @doc """
  Send `:terminate` to the invocation process identified by `invocation_id`.

  Returns `:ok` when an invocation is registered under the given id and the
  message is delivered, or `{:error, :not_found}` when no invocation is
  registered. The Registry stores the invocation pid as the entry value
  while the calling process owns the entry; this function extracts the
  invocation pid and sends `:terminate` to it.
  """
  @spec terminate_invocation(invocation_id()) :: :ok | {:error, term()}
  def terminate_invocation(invocation_id) do
    case Registry.lookup(registry_name(), invocation_id) do
      [{pid, _value}] ->
        send(pid, :terminate)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  # Returns the Registry name for the most recently started supervisor
  # instance. Tests and production both run a single named supervisor at
  # a time, so a single key is sufficient.
  defp registry_name, do: :persistent_term.get(@registry_key)

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
      {:ok, pid} ->
        # Register the invocation so `terminate_invocation/1` can find the
        # pid by ref. The caller owns the registry entry; the value is the
        # invocation pid. If the caller dies before the invocation completes
        # the entry is reaped automatically. The registry name is read from
        # the persistent_term key published by this supervisor's `init/1`.
        {:ok, _owner} = Registry.register(registry_name(), ref, pid)
        {:ok, pid, ref}

      other ->
        other
    end
  end
end
