defmodule ForemanServer.ProjectSupervisor do
  @moduledoc """
  TRD-003: ProjectSupervisor.

  Thin wrapper that:
  * ensures the canonical `Aggregator` supervisor and `ProjectRegistry`
    are running,
  * starts project aggregate actors through `Aggregator.start_aggregate/2`
    so they live under the global aggregate supervisor tree (and get
    `:permanent` restart semantics), and
  * records the project_id → pid mapping via `ProjectRegistry`.

  Crashed project processes are restarted by the `Aggregator` supervisor;
  `:DOWN` notifications cause the registry to drop the stale mapping.
  """

  alias ForemanServer.{Aggregator, ProjectRegistry}

  @doc "Start a project process and register it."
  @spec start_project(String.t()) :: {:ok, pid()} | {:error, term()}
  def start_project(project_id) when is_binary(project_id) do
    case ProjectRegistry.lookup(project_id) do
      {:ok, pid} ->
        {:ok, pid}

      :error ->
        do_start(project_id)
    end
  end

  defp do_start(project_id) do
    case Aggregator.start_aggregate(ForemanServer.Aggregates.Project, project_id) do
      {:ok, pid} ->
        :ok = ProjectRegistry.register(project_id, pid)
        {:ok, pid}

      other ->
        other
    end
  end

  @doc "Stop a project process."
  @spec stop_project(String.t()) :: :ok | {:error, :not_found}
  def stop_project(project_id) when is_binary(project_id) do
    case ProjectRegistry.lookup(project_id) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Process.exit(pid, :shutdown)

        receive do
          {:DOWN, ^ref, :process, _, _} -> :ok
        after
          5_000 -> :ok
        end

        ProjectRegistry.unregister(project_id)
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc "List live project ids."
  @spec list_projects() :: [String.t()]
  def list_projects, do: ProjectRegistry.list_project_ids()
end
