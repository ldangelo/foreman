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
    {:reply, Map.keys(state.projects) |> Enum.sort(), state}
  end

  def handle_call({:ensure_project, %Project{} = project}, _from, state) do
    case start_project(project) do
      {:ok, pid} ->
        {:reply, {:ok, pid}, put_in(state.projects[project.id], project)}

      {:error, {:already_started, pid}} ->
        {:reply, {:ok, pid}, put_in(state.projects[project.id], project)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp start_projects(projects, state) do
    Enum.reduce(projects, state, fn project, acc ->
      case start_project(project) do
        {:ok, _pid} -> put_in(acc.projects[project.id], project)
        {:error, {:already_started, _pid}} -> put_in(acc.projects[project.id], project)
        {:error, reason} -> raise "failed to start project #{project.id}: #{inspect(reason)}"
      end
    end)
  end

  defp start_project(%Project{status: :inactive}), do: {:error, :inactive_project}

  defp start_project(%Project{} = project) do
    DynamicSupervisor.start_child(
      ForemanServer.ProjectDynamicSupervisor,
      {ProjectSupervisor, project}
    )
  end
end
