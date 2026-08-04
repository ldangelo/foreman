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
  Start a new invocation process.

  The caller provides:
  - `adapter_module` — the backend adapter to invoke
  - `request` — the execution request map
  - `caller` — the PID to receive the result
  - `supervisor` — the supervisor to start the invocation under (optional, defaults to __MODULE__)

  Returns `{:ok, invocation_pid, invocation_ref}`.
  """
  @spec start_invocation(module(), map(), pid(), GenServer.server()) :: {:ok, pid(), reference()} | DynamicSupervisor.on_start_child()
  def start_invocation(adapter_module, request, caller, supervisor \\ __MODULE__) do
    ref = make_ref()
    spec = {ForemanServer.AgentRuntime.Invocation, {adapter_module, request, caller, ref}}
    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, pid} -> {:ok, pid, ref}
      other -> other
    end
  end
end
