defmodule ForemanServer.Workflow.BootReconciliation do
  @moduledoc """
  Reconciles provider coordination state against Foreman's in-progress runs on boot,
  and re-acknowledges task–run bindings whose run became terminal while the
  Dispatcher was down.

  Two responsibilities share the process:

    * `reconcile/0` — drives the provider-claim pass that reopens orphaned
      in-progress issues whose run no longer exists (the original
      `BootReconciliation drives orphan-reopen` contract).
    * `scan_task_run_orphans/0` — iterates `ProjectionStore.list_tasks/0`
      looking for tasks whose `run_id` is bound to a terminal run whose
      run id has not yet been copied into `acknowledged_run_id`. Each
      orphan is dispatched as `task.run_terminated` so the task can be
      retried via the `foreman task retry` operator command.

  The task-run scan covers orphans missed while the Dispatcher was down
  or pre-subscription (`ProjectionStore.subscribe/0` does not replay
  history). The Dispatcher fans live terminal run events into the API
  on `run_terminated/2` so the same dispatch path covers future
  terminals.
  """

  use GenServer

  require Logger

  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore, Telemetry}
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry

  @orphan_reopen_event [:foreman_server, :workflow, :boot_reconciliation, :orphan_reopen]
  @matching_in_progress_event [
    :foreman_server,
    :workflow,
    :boot_reconciliation,
    :matching_in_progress
  ]
  @already_closed_event [:foreman_server, :workflow, :boot_reconciliation, :already_closed]
  @healthy_event [:foreman_server, :workflow, :boot_reconciliation, :healthy]
  @transition_comment "foreman-run-reconciled"
  @json_schema_cache_name :foreman_server_json_schema_cache

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(init_arg \\ []) do
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec reconcile() :: :ok
  def reconcile do
    runs_by_project = active_runs_by_project()

    ProjectionStore.list_projects()
    |> Enum.each(&reconcile_project(&1, runs_by_project))

    :ok
  end

  @doc """
  Request a scan of every projected task for an orphan binding — a task
  whose `run_id` points at a terminal run whose id has not yet been
  copied into `acknowledged_run_id`. Each orphan is dispatched as
  `task.run_terminated` so the task can be retried via the
  `foreman task retry` operator command.

  Dispatches as a cast so the actual scan runs inside the
  `BootReconciliation` process. If `CommandRouter` is not yet registered
  the cast handler defers the scan via `:scan_orphans` until it is. The
  function never reads task provider state. Returns `:ok` once the cast
  is enqueued.
  """
  @spec scan_task_run_orphans() :: :ok
  def scan_task_run_orphans do
    GenServer.cast(__MODULE__, :scan_orphans)
    :ok
  end

  @doc """
  Cast a live terminal-run notification. The Dispatcher calls this on
  every `RunCancelled`, `RunFlaggedStuck`, `RunCompleted`, and `RunFailed`
  projection event so the fan-out path is identical to the boot scan.

  Routes through `CommandRouter` readiness: when the router is registered
  the cast dispatches `task.run_terminated` against every task bound to
  `run_id`; otherwise the run joins the same `:scan_orphans` deferral
  loop the boot path uses, so no terminal run is silently lost during
  startup.
  """
  @spec run_terminated(String.t(), String.t()) :: :ok
  def run_terminated(run_id, reason)
      when is_binary(run_id) and run_id != "" and is_binary(reason) do
    GenServer.cast(__MODULE__, {:run_terminated, run_id, reason})
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{reconciled?: false, scanned?: false}, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    reconcile()
    run_scan_or_defer()
    {:noreply, %{state | reconciled?: true}}
  end

  @impl true
  def handle_cast({:run_terminated, run_id, reason}, state) do
    if command_router_ready?() do
      fan_out_task_run_terminated(run_id, reason)
    else
      schedule_scan(:not_ready)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:scan_orphans, state) do
    run_scan_or_defer()
    {:noreply, state}
  end

  @impl true
  def handle_info(:scan_orphans, state) do
    run_scan_or_defer()
    {:noreply, state}
  end

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp active_runs_by_project do
    ProjectionStore.list_runs()
    |> Enum.reduce(%{}, fn run, acc ->
      if fetch_status(run) == "in_progress" do
        with {:ok, project_id} <- fetch_project_id(run),
             {:ok, task_id} <- fetch_task_id(run) do
          Map.update(acc, project_id, MapSet.new([task_id]), &MapSet.put(&1, task_id))
        else
          _ -> acc
        end
      else
        acc
      end
    end)
  end

  defp reconcile_project(project, runs_by_project) do
    with {:ok, project_id} <- fetch_project_id(project),
         {:ok, task_provider} <- fetch_task_provider(project),
         {:ok, project_config} <- fetch_project_config(task_provider),
         {:ok, database_path} <- fetch_database_path(project_config),
         {:ok, provider_module} <-
           TaskProviderRegistry.route(:reopen, {project_id, database_path}),
         :ok <- ensure_coordination_status(provider_module),
         {:ok, issues} <- provider_module.coordination_status(project_config) do
      active_task_ids = Map.get(runs_by_project, project_id, MapSet.new())

      Enum.each(issues, fn issue ->
        reconcile_issue(issue, active_task_ids, provider_module, project_config, project_id)
      end)
    else
      {:error, reason} ->
        log_skip(project, reason)

      :error ->
        :ok
    end
  rescue
    exception ->
      Logger.warning(
        "BootReconciliation failed for project #{inspect(fetch_map_value(project, :project_id))}: #{Exception.message(exception)}"
      )

      :ok
  end

  defp reconcile_issue(
         %Issue{} = issue,
         active_task_ids,
         provider_module,
         project_config,
         project_id
       ) do
    has_matching_run? = MapSet.member?(active_task_ids, issue.id)

    case {issue.status, has_matching_run?} do
      {"in_progress", false} ->
        case ensure_json_schema_cache_started() do
          :ok ->
            case provider_module.reopen(issue.id, @transition_comment, project_config) do
              :ok -> emit(@orphan_reopen_event, project_id, issue, false)
              {:ok, _result} -> emit(@orphan_reopen_event, project_id, issue, false)
              {:error, reason} -> log_reopen_failure(project_id, issue.id, reason)
            end

          {:error, reason} ->
            log_reopen_failure(project_id, issue.id, reason)
        end

      {"in_progress", true} ->
        emit(@matching_in_progress_event, project_id, issue, true)

      {"closed", true} ->
        emit(@already_closed_event, project_id, issue, true)

      _other ->
        emit(@healthy_event, project_id, issue, has_matching_run?)
    end
  end

  defp reconcile_issue(_issue, _active_task_ids, _provider_module, _project_config, _project_id),
    do: :ok

  defp ensure_coordination_status(provider_module) when is_atom(provider_module) do
    if function_exported?(provider_module, :coordination_status, 1) do
      :ok
    else
      {:error, :coordination_status_not_supported}
    end
  end

  defp ensure_json_schema_cache_started do
    case Process.whereis(@json_schema_cache_name) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        if application_supervisor = Process.whereis(ForemanServer.Application) do
          case Supervisor.start_child(
                 application_supervisor,
                 ForemanServer.TaskProviders.JsonSchemaCache
               ) do
            {:ok, _pid} -> :ok
            {:ok, _pid, _info} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, :already_present} -> :ok
            {:error, reason} -> {:error, reason}
          end
        else
          case ForemanServer.TaskProviders.JsonSchemaCache.start_link() do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
    end
  end

  defp emit(event, project_id, %Issue{} = issue, has_matching_run?) do
    Telemetry.execute(event, %{count: 1}, %{
      project_id: project_id,
      issue_id: issue.id,
      status: issue.status,
      has_matching_run?: has_matching_run?
    })
  end

  defp fetch_project_id(map) when is_map(map) do
    case fetch_map_value(map, :project_id) do
      project_id when is_binary(project_id) and project_id != "" -> {:ok, project_id}
      _ -> :error
    end
  end

  defp fetch_task_id(map) when is_map(map) do
    case fetch_map_value(map, :task_id) do
      task_id when is_binary(task_id) and task_id != "" -> {:ok, task_id}
      _ -> :error
    end
  end

  defp fetch_status(map) when is_map(map) do
    fetch_map_value(map, :status)
  end

  defp fetch_task_provider(project) do
    task_provider =
      Map.get(project, :task_provider) ||
        Map.get(project, "task_provider") ||
        get_in(project, [:config, :task_provider]) ||
        get_in(project, [:config, "task_provider"])

    if is_map(task_provider),
      do: {:ok, task_provider},
      else: {:error, :task_provider_not_configured}
  end

  defp fetch_project_config(task_provider) do
    project_config = Map.get(task_provider, :config) || Map.get(task_provider, "config")

    if is_map(project_config),
      do: {:ok, project_config},
      else: {:error, :task_provider_not_configured}
  end

  defp fetch_database_path(project_config) do
    case fetch_map_value(project_config, :database_path) do
      database_path when is_binary(database_path) and database_path != "" -> {:ok, database_path}
      _ -> {:error, :task_provider_not_configured}
    end
  end

  defp fetch_map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp log_skip(project, reason) do
    project_id = fetch_map_value(project, :project_id) || "unknown"
    Logger.debug("BootReconciliation skipping project #{inspect(project_id)}: #{inspect(reason)}")
  end

  defp log_reopen_failure(project_id, issue_id, reason) do
    Logger.warning(
      "BootReconciliation failed reopening #{inspect(issue_id)} for project #{inspect(project_id)}: #{inspect(reason)}"
    )
  end

  defp orphan_task?(task) when is_map(task) do
    run_id = fetch_map_value(task, :run_id)
    ack_run_id = fetch_map_value(task, :acknowledged_run_id)

    is_binary(run_id) and run_id != "" and run_id != ack_run_id and
      fetch_map_value(task, :status) == "in_progress" and run_terminal?(run_id)
  end

  defp orphan_task?(_), do: false

  defp run_terminal?(run_id) do
    case ProjectionStore.run(run_id) do
      nil -> false
      run -> fetch_map_value(run, :terminal?) == true
    end
  end

  defp ack_orphan_task(task) do
    task_id = fetch_map_value(task, :task_id)
    run_id = fetch_map_value(task, :run_id)

    if is_binary(task_id) and task_id != "" and is_binary(run_id) and run_id != "" do
      reason =
        case ProjectionStore.run(run_id) do
          nil -> "run_terminated"
          run -> fetch_map_value(run, :status) || "run_terminated"
        end

      dispatch_task_run_terminated(task_id, run_id, reason)
    end
  end

  defp fan_out_task_run_terminated(run_id, reason) do
    ProjectionStore.tasks_by_run_id(run_id)
    |> Enum.each(fn task ->
      task_id = fetch_map_value(task, :task_id)
      dispatch_task_run_terminated(task_id, run_id, reason)
    end)
  end

  defp dispatch_task_run_terminated(task_id, run_id, reason) do
    if is_binary(task_id) and task_id != "" do
      CommandGateway.dispatch_system(%{
        type: "task.run_terminated",
        command_id: "foreman:task-ack:#{task_id}:#{run_id}",
        aggregate_id: "task:#{task_id}",
        payload: %{
          task_id: task_id,
          run_id: run_id,
          reason: reason,
          acknowledged_at: iso8601_now()
        }
      })
    end
  end

  defp iso8601_now do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()

    :io_lib.format(
      "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0BZ",
      [y, mo, d, h, mi, s]
    )
    |> List.to_string()
  end

  @scan_retry_ms 50

  defp run_scan_or_defer do
    if command_router_ready?() do
      do_scan_task_run_orphans()
    else
      schedule_scan(:not_ready)
    end
  end

  defp do_scan_task_run_orphans do
    tasks = ProjectionStore.list_tasks()
    orphans = Enum.filter(tasks, &orphan_task?/1)

    Enum.each(orphans, &ack_orphan_task/1)
    :ok
  end

  defp schedule_scan(:not_ready) do
    Process.send_after(self(), :scan_orphans, @scan_retry_ms)
  end

  defp command_router_ready? do
    is_pid(Process.whereis(CommandRouter))
  end
end
