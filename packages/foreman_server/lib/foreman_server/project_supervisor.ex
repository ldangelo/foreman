defmodule ForemanServer.ProjectSupervisor do
  @moduledoc "Supervised process representing one active Foreman project."

  use GenServer

  alias ForemanServer.{Project, ProjectRegistry}

  @spec start_link(Project.t()) :: GenServer.on_start()
  def start_link(%Project{id: id} = project) do
    GenServer.start_link(__MODULE__, project, name: ProjectRegistry.via(id))
  end

  @spec child_spec(Project.t()) :: Supervisor.child_spec()
  def child_spec(%Project{id: id} = project) do
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [project]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @spec project(String.t()) :: Project.t() | nil
  def project(id) do
    case ProjectRegistry.lookup(id) do
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
