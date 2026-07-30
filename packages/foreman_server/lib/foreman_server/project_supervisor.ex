defmodule ForemanServer.ProjectSupervisor do
  @moduledoc """
  OTP supervisor for one project's process tree.

  Children:
    - `ProjectWorker` — holds `%Project{}` state and registers under `:project_registry`

  Exposes `start_project/1` which is idempotent: if the project is already registered
  and the worker is alive, it returns the existing worker pid without starting a
  duplicate supervisor. If the registered pid is dead (stale entry), it starts a new
  supervisor and recovers the project.
  """

  use Supervisor

  alias ForemanServer.{Project, ProjectRegistry, ProjectWorker}

  @spec start_link(Project.t()) :: Supervisor.on_start()
  def start_link(%Project{} = project) do
    Supervisor.start_link(__MODULE__, project)
  end

  @spec start_project(Project.t()) :: {:ok, pid()} | {:error, term()}
  def start_project(%Project{} = project) do
    idempotent_start_project(project)
  end

  @spec project(String.t()) :: Project.t() | nil
  def project(project_id), do: ProjectWorker.project(project_id)

  @impl true
  def init(%Project{} = project) do
    children = [
      {ProjectWorker, project}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Idempotent start: look up first, verify aliveness, only start if absent or dead.
  defp idempotent_start_project(%Project{status: :inactive}), do: {:error, :inactive_project}

  defp idempotent_start_project(%Project{id: id} = project) do
    case ProjectRegistry.lookup(id) do
      {:ok, pid} ->
        if is_pid(pid) and Process.alive?(pid) do
          {:ok, pid}
        else
          # Stale entry: pid is registered but dead. Start a new supervisor.
          do_start_supervisor(project)
        end

      :error ->
        do_start_supervisor(project)
    end
  end

  defp do_start_supervisor(%Project{id: id} = project) do
    case DynamicSupervisor.start_child(
           ForemanServer.ProjectDynamicSupervisor,
           {__MODULE__, project}
         ) do
      {:ok, _supervisor_pid} ->
        {:ok, worker_pid_from_lookup(id)}

      {:error, {:already_started, _supervisor_pid}} ->
        {:ok, worker_pid_from_lookup(id)}

      {:error, :already_started} ->
        {:ok, worker_pid_from_lookup(id)}

      {:error, {:shutdown, {:failed_to_start_child, ProjectWorker, {:already_started, _}}}} ->
        # Concurrent race: another process started ProjectWorker just before us.
        # Its supervisor may have crashed (we won the supervisor slot); re-lookup
        # the already-registered worker.
        {:ok, worker_pid_from_lookup(id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Retry lookup in case the winning worker hasn't registered yet.
  defp worker_pid_from_lookup(id) do
    worker_pid_from_lookup(id, 50)
  end

  defp worker_pid_from_lookup(id, 0) do
    raise "project_worker #{id} failed to register in :project_registry"
  end

  defp worker_pid_from_lookup(id, retries) do
    case ProjectRegistry.lookup(id) do
      {:ok, pid} ->
        if Process.alive?(pid), do: pid, else: retry_or_raise(id, retries)

      :error ->
        retry_or_raise(id, retries)
    end
  end

  defp retry_or_raise(id, 0),
    do: raise("project_worker #{id} failed to register in :project_registry")

  defp retry_or_raise(id, retries) do
    Process.sleep(1)
    worker_pid_from_lookup(id, retries - 1)
  end
end
