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
    start_invocation_impl(candidates, policy, request, caller, supervisor)
  end

  @doc """
  Start a new invocation process.

  The caller provides:
  - `candidates` — ordered list of `{adapter_module, available?}` tuples
  - `policy` — resolved failure policy map with :fallback, :max_attempts, :timeout_ms
  - `request` — the execution request map with :prompt and :context
  - `caller` — the PID to receive the result
  - `supervisor` — the supervisor to start the invocation under (optional, defaults to __MODULE__)

  Returns `{:ok, invocation_pid, invocation_ref}`.
  """
  @spec start_invocation([candidate()], map(), map(), pid(), GenServer.server()) ::
          {:ok, pid(), reference()} | DynamicSupervisor.on_start_child()
  def start_invocation(candidates, policy, request, caller, supervisor)
      when is_list(candidates) do
    start_invocation_impl(candidates, policy, request, caller, supervisor)
  end

  # Default supervisor version
  def start_invocation(candidates, policy, request, caller) do
    start_invocation_impl(candidates, policy, request, caller, __MODULE__)
  end

  # Implementation
  defp start_invocation_impl(candidates, policy, request, caller, supervisor) do
    ref = make_ref()
    spec = {Invocation, {candidates, policy, request, caller, ref}}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> {:ok, pid, ref}
      other -> other
    end
  end
end
