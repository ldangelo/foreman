defmodule ForemanServer.Workflow.BootReconciliation do
  @moduledoc """
  Reconciles provider coordination state against Foreman's in-progress runs on boot.
  """

  use GenServer

  require Logger

  alias ForemanServer.{ProjectionStore, Telemetry}
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

  @impl true
  def init(_init_arg) do
    {:ok, %{reconciled?: false}, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    reconcile()
    {:noreply, %{state | reconciled?: true}}
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
end
