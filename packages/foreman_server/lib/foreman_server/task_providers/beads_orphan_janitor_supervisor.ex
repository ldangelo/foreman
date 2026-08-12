defmodule ForemanServer.TaskProviders.BeadsOrphanJanitorSupervisor do
  @moduledoc """
  `DynamicSupervisor` that owns one
  `ForemanServer.TaskProviders.BeadsOrphanJanitor` child per registered project.

  Mirrors `BeadsWatcherSupervisor` for the orphan-reopen sweep: children are
  spawned on demand by the `ProjectProviderProjector` after a successful
  registration, and torn down when the projector calls
  `unregister_for_project/2`.

  Supervision is opt-in via `:start_beads_orphan_janitor?` (default `false`).
  Children use `restart: :permanent` and register under a per-project
  `{:via, Registry, ...}` name — `DynamicSupervisor.which_children/1` is
  unreliable for ad-hoc ids, so PID lookup goes through the Registry that
  `init/1` co-locates with this supervisor.
  """

  use DynamicSupervisor

  alias ForemanServer.TaskProviders.BeadsOrphanJanitor

  @registry __MODULE__.Registry

  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a `BeadsOrphanJanitor` child for `project_id` against `database_path`.
  """
  @spec start_child(String.t(), String.t()) ::
          {:ok, pid()} | {:error, {:already_started, pid()}} | {:error, term()}
  def start_child(project_id, database_path)
      when is_binary(project_id) and is_binary(database_path) do
    child_spec = %{
      id: project_id,
      start:
        {BeadsOrphanJanitor, :start_link,
         [
           [
             project_id: project_id,
             database_path: database_path,
             name: {:via, Registry, {@registry, project_id}}
           ]
         ]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @doc """
  Stop the `BeadsOrphanJanitor` child for `project_id`, if running.
  """
  @spec stop_child(String.t()) :: :ok | {:error, :not_found} | {:error, term()}
  def stop_child(project_id) when is_binary(project_id) do
    case Registry.lookup(@registry, project_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end

  @doc """
  List currently-running janitor children via the Registry.
  """
  @spec which_children() :: [{String.t(), pid()}]
  def which_children do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc "Look up the janitor PID for `project_id`."
  @spec lookup(String.t()) :: pid() | nil
  def lookup(project_id) when is_binary(project_id) do
    case Registry.lookup(@registry, project_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Read the janitor's most recent scan counters for `project_id`.

  Returns:
    * `{:ok, counters}` — janitor is running and has completed at least one scan.
    * `{:ok, nil}` — janitor is running but no scan has completed yet.
    * `{:error, :not_running}` — no janitor is registered for `project_id`.

  This is a SIDE-EFFECT-FREE read against the janitor's in-memory state.
  It does NOT invoke `run_scan/2`, does NOT call `BeadsAdapter.complete/3`,
  and does NOT dispatch through `CommandRouter`. The doctor and other
  diagnostic surfaces MUST use this entry point; calling `run_scan/2`
  from a read path would mutate provider state and violate the CQRS
  query boundary.
  """
  @spec snapshot(String.t()) ::
          {:ok, BeadsOrphanJanitor.counters() | nil} | {:error, :not_running}
  def snapshot(project_id) when is_binary(project_id) do
    # Guard: the supervisor (and its co-located Registry) may not be started
    # when `:start_beads_orphan_janitor?` is false. `Registry.lookup/2` would
    # crash with ArgumentError if the Registry process is not running, so
    # we surface `:not_running` instead of letting the doctor crash.
    if Process.whereis(__MODULE__) == nil do
      {:error, :not_running}
    else
      case lookup(project_id) do
        nil -> {:error, :not_running}
        pid -> {:ok, BeadsOrphanJanitor.get_counters(pid)}
      end
    end
  end

  @impl true
  def init(_opts) do
    case Registry.start_link(keys: :unique, name: @registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 100, max_seconds: 5)
  end
end
