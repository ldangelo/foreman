defmodule ForemanServer.TaskProviders.BeadsWatcherSupervisor do
  @moduledoc """
  `DynamicSupervisor` that owns one `ForemanServer.TaskProviders.BeadsWatcher`
  child per registered project.

  Children are spawned on demand by the `ProjectProviderProjector` once a
  project registration passes preflight and `TaskProvider.Registry.register_for_project/3`
  returns `:ok`. They are torn down when the projector calls
  `unregister_for_project/2`.

  Supervision is opt-in via `:start_beads_watcher?` (default `false`). The
  projector is responsible for honoring the flag — when the supervisor is
  not running, projector calls are no-ops.

  Children use `restart: :permanent` (per project spec) and register under a
  per-project `{:via, Registry, ...}` name. The `Registry` is co-located
  with the supervisor (started inside `init/1`); this is required because
  `DynamicSupervisor.which_children/1` reports child ids as `:undefined`,
  so per-project PID lookup must go through a stable name.

  Lookup for `stop_child/1` uses the registry, never `which_children/1`.
  """

  use DynamicSupervisor

  alias ForemanServer.TaskProviders.BeadsWatcher

  @registry __MODULE__.Registry

  @spec start_link(keyword()) :: DynamicSupervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start a `BeadsWatcher` child for `project_id` against `database_path`.
  """
  @spec start_child(String.t(), String.t()) ::
          {:ok, pid()} | {:error, {:already_started, pid()}} | {:error, term()}
  def start_child(project_id, database_path)
      when is_binary(project_id) and is_binary(database_path) do
    child_spec = %{
      id: project_id,
      start:
        {BeadsWatcher, :start_link,
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
  Stop the `BeadsWatcher` child for `project_id`, if running.
  """
  @spec stop_child(String.t()) :: :ok | {:error, :not_found} | {:error, term()}
  def stop_child(project_id) when is_binary(project_id) do
    case Registry.lookup(@registry, project_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> :ok
    end
  end

  @doc """
  List currently-running watcher children via the Registry.
  """
  @spec which_children() :: [{String.t(), pid()}]
  def which_children do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc "Look up the watcher PID for `project_id`."
  @spec lookup(String.t()) :: pid() | nil
  def lookup(project_id) when is_binary(project_id) do
    case Registry.lookup(@registry, project_id) do
      [{pid, _}] -> pid
      [] -> nil
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
