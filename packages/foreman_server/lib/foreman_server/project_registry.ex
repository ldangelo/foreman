defmodule ForemanServer.ProjectRegistry do
  @moduledoc "Loads configured projects and ensures one supervised process per active project."

  use GenServer

  alias ForemanServer.{Project, ProjectStore, ProjectSupervisor}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec active_project_ids() :: [String.t()]
  def active_project_ids do
    GenServer.call(__MODULE__, :active_project_ids)
  end

  @spec ensure_project(Project.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_project(%Project{} = project) do
    GenServer.call(__MODULE__, {:ensure_project, project})
  end

  @type project_id :: String.t()

  @spec via(project_id) :: {:via, Registry, {:project_registry, project_id}}
  def via(project_id) when is_binary(project_id) do
    {:via, Registry, {:project_registry, project_id}}
  end

  @spec register(project_id, pid()) :: :ok | {:error, :already_registered | :not_self}
  def register(project_id, pid) when is_binary(project_id) and is_pid(pid) do
    if pid == self() do
      case Registry.register(:project_registry, project_id, pid) do
        {:ok, _} -> :ok
        {:error, {:already_registered, _}} -> {:error, :already_registered}
      end
    else
      {:error, :not_self}
    end
  end

  @spec unregister(project_id) :: :ok
  def unregister(project_id) when is_binary(project_id) do
    Registry.unregister(:project_registry, project_id)
    :ok
  end

  @spec lookup(project_id) :: {:ok, pid()} | :error
  def lookup(project_id) when is_binary(project_id) do
    case Registry.lookup(:project_registry, project_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @impl true
  def init(_opts) do
    case ProjectStore.load_projects() do
      {:ok, projects, source} ->
        state = %{projects: %{}, source: source}
        {:ok, start_projects(projects, state)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:active_project_ids, _from, state) do
    project_ids =
      Registry.select(:project_registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.sort()

    {:reply, project_ids, state}
  end

  def handle_call({:ensure_project, %Project{} = project}, _from, state) do
    case start_project(project) do
      {:ok, pid} ->
        {:reply, {:ok, pid}, put_in(state.projects[project.id], project)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp start_projects(projects, state) do
    Enum.reduce(projects, state, fn project, acc ->
      case start_project(project) do
        {:ok, _pid} -> put_in(acc.projects[project.id], project)
        {:error, reason} -> raise "failed to start project #{project.id}: #{inspect(reason)}"
      end
    end)
  end

  defp start_project(%Project{} = project), do: ProjectSupervisor.start_project(project)
end
