defmodule ForemanServer.ProjectRegistry do
  @moduledoc """
  TRD-002: ProjectRegistry GenServer.

  Provides a canonical name → pid map for project processes. Built on top
  of Elixir's `Registry` (`:project_registry` keys), this module exposes
  simple `register/2`, `unregister/1`, and `lookup/1` helpers and a `via/1`
  helper for use with `GenServer.start_link`.
  """

  use GenServer

  @registry_name :project_registry

  defmodule State do
    @moduledoc false
    defstruct monitors: %{}
  end

  @doc "Start the ProjectRegistry process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register a project process under `project_id`."
  @spec register(String.t(), pid()) :: :ok | {:error, {:already_registered, String.t()}}
  def register(project_id, pid) when is_binary(project_id) and is_pid(pid) do
    GenServer.call(__MODULE__, {:register, project_id, pid})
  end

  @doc "Remove a project_id mapping."
  @spec unregister(String.t()) :: :ok
  def unregister(project_id) when is_binary(project_id) do
    GenServer.call(__MODULE__, {:unregister, project_id})
  end

  @doc "Look up a pid by project_id."
  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(project_id) when is_binary(project_id) do
    case Registry.lookup(@registry_name, project_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc "Build a `{:via, Registry, ...}` tuple for `GenServer.start_link`."
  @spec via(String.t()) :: {:via, Registry, {atom(), String.t()}}
  def via(project_id) when is_binary(project_id),
    do: {:via, Registry, {@registry_name, project_id}}

  @doc "List every registered project_id."
  @spec list_project_ids() :: [String.t()]
  def list_project_ids do
    @registry_name
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end

  @impl true
  def init(_opts) do
    case Registry.start_link(keys: :unique, name: @registry_name, partitions: 1) do
      {:ok, _owner} -> {:ok, %State{}}
      {:error, {:already_started, _pid}} -> {:ok, %State{}}
    end
  end

  @impl true
  def handle_call({:register, project_id, pid}, _from, state) do
    case Registry.register(@registry_name, project_id, pid) do
      {:ok, _owner} ->
        ref = Process.monitor(pid)
        monitors = Map.put(state.monitors, ref, project_id)
        {:reply, :ok, %{state | monitors: monitors}}

      {:error, {:already_registered, _pid}} ->
        {:reply, {:error, {:already_registered, project_id}}, state}
    end
  end

  def handle_call({:unregister, project_id}, _from, state) do
    Registry.unregister(@registry_name, project_id)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      case Map.pop(state.monitors, ref) do
        {nil, _} ->
          state

        {project_id, monitors} ->
          Registry.unregister(@registry_name, project_id)
          %{state | monitors: monitors}
      end

    {:noreply, state}
  end
end
