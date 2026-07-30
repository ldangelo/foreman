defmodule ForemanServer.ProjectWorker do
  @moduledoc "Leaf process for a single project. Registered under ProjectRegistry via :via tuple."

  use GenServer

  alias ForemanServer.{Project, ProjectRegistry}

  @spec start_link(Project.t()) :: GenServer.on_start()
  def start_link(%Project{} = project) do
    GenServer.start_link(__MODULE__, project, name: ProjectRegistry.via(project.id))
  end

  @spec project(String.t()) :: Project.t() | nil
  def project(project_id) do
    case ProjectRegistry.lookup(project_id) do
      {:ok, pid} -> GenServer.call(pid, :project)
      :error -> nil
    end
  end

  @impl true
  def init(%Project{} = project) do
    {:ok, project}
  end

  @impl true
  def handle_call(:project, _from, project) do
    {:reply, project, project}
  end
end
