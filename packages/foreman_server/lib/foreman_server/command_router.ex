defmodule ForemanServer.CommandRouter do
  @moduledoc "Command boundary for server-side project/task mutations."

  alias ForemanServer.{
    EventStore,
    IntegrationIngestion,
    MigrationImporter,
    PlanningFlow,
    ProjectionStore,
    Scheduler,
    Security
  }

  @external_trigger_types ["ExternalTriggerCommand", "external.trigger"]
  @planning_command_types ["PlanningFlowCommand", "plan.prd", "plan.trd"]
  @migration_command_types ["MigrationImportCommand", "migration.import"]

  @spec handle(map()) :: {:ok, map()} | {:error, term()}
  def handle(%{"command_type" => command_type} = command)
      when command_type in @planning_command_types do
    command
    |> normalize_payload()
    |> Map.put(:command_type, command_type)
    |> Map.put_new(:command_id, external_command_id(command))
    |> handle()
  end

  def handle(%{"command_type" => command_type} = command)
      when command_type in @migration_command_types do
    command
    |> normalize_payload()
    |> Map.put(:command_type, command_type)
    |> Map.put_new(:command_id, external_command_id(command))
    |> handle()
  end

  def handle(%{"command_type" => command_type} = command)
      when command_type in @external_trigger_types do
    command
    |> normalize_payload()
    |> Map.put(:command_type, command_type)
    |> Map.put_new(:command_id, external_command_id(command))
    |> handle()
  end

  def handle(%{"command_id" => command_id, "command_type" => command_type} = command) do
    handle(%{
      command_id: command_id,
      command_type: command_type,
      correlation_id: Map.get(command, "correlation_id"),
      payload: Map.get(command, "payload", %{}),
      metadata: Map.get(command, "metadata", %{})
    })
  end

  def handle(%{command_type: command_type} = command)
      when command_type in @planning_command_types do
    command_id = Map.get(command, :command_id) || external_command_id(command)
    metadata = normalize_metadata(Map.put(command, :command_id, command_id))

    command
    |> planning_payload(command_type)
    |> Map.put_new(:command_id, command_id)
    |> handle_planning_flow(metadata)
  end

  def handle(%{command_type: command_type} = command)
      when command_type in @migration_command_types do
    command_id = Map.get(command, :command_id) || external_command_id(command)
    metadata = normalize_metadata(Map.put(command, :command_id, command_id))

    command
    |> migration_payload()
    |> Map.put_new(:command_id, command_id)
    |> Map.put_new(:migration_id, command_id)
    |> handle_migration_import(metadata)
  end

  def handle(%{command_type: command_type} = command)
      when command_type in @external_trigger_types do
    command_id = Map.get(command, :command_id) || external_command_id(command)
    metadata = normalize_metadata(Map.put(command, :command_id, command_id))

    command
    |> external_trigger_payload()
    |> Map.put_new(:command_id, command_id)
    |> handle_external_trigger(metadata)
  end

  def handle(%{command_id: command_id, command_type: command_type} = command)
      when is_binary(command_id) and is_binary(command_type) do
    payload =
      command
      |> Map.get(:payload, %{})
      |> normalize_payload()
      |> Map.put_new(:command_id, command_id)

    metadata = normalize_metadata(command)

    with {:ok, event_type, event_payload, stream_id} <- domain_event(command_type, payload),
         enriched_payload =
           event_payload
           |> Map.put_new(:command_id, command_id)
           |> Map.put_new(:updated_at, DateTime.utc_now()),
         {:ok, event} <-
           EventStore.append(%{
             stream_id: stream_id,
             event_type: event_type,
             payload: enriched_payload,
             metadata: metadata,
             correlation_id: Map.get(metadata, :correlation_id)
           }),
         {:ok, audit_events} <- maybe_audit(command, event_type, enriched_payload) do
      maybe_schedule_dispatch(event_type, enriched_payload)
      {:ok, %{event: event, audit_events: audit_events, projection: ProjectionStore.snapshot()}}
    end
  end

  def handle(_command), do: {:error, :invalid_command}

  defp domain_event("project.register", payload) do
    project_id = Map.get(payload, :project_id) || Map.get(payload, :id)

    with {:ok, project_id} <- required_binary(project_id, :project_id),
         {:ok, path} <- required_binary(Map.get(payload, :path), :path) do
      {:ok, "ProjectRegistered",
       %{
         project_id: project_id,
         path: path,
         status: Map.get(payload, :status, "active"),
         default_branch: Map.get(payload, :default_branch, "main"),
         config: Map.get(payload, :config, %{}),
         health: Map.get(payload, :health, %{ok: true})
       }, "project:#{project_id}"}
    end
  end

  defp domain_event("task.create", payload) do
    task_id = Map.get(payload, :task_id) || Map.get(payload, :id)

    if is_binary(task_id) and task_id != "" do
      {:ok, "TaskCreated",
       %{
         task_id: task_id,
         project_id: Map.get(payload, :project_id),
         title: Map.get(payload, :title, task_id),
         description: Map.get(payload, :description),
         priority: Map.get(payload, :priority),
         status: Map.get(payload, :status, "open"),
         dependencies: Map.get(payload, :dependencies, []),
         task_type: Map.get(payload, :task_type) || Map.get(payload, :type),
         source: Map.get(payload, :source),
         external_id: Map.get(payload, :external_id),
         external_link: Map.get(payload, :external_link),
         dedupe_key: Map.get(payload, :dedupe_key),
         integration_event_type: Map.get(payload, :integration_event_type),
         planning_run_id: Map.get(payload, :planning_run_id),
         planning_kind: Map.get(payload, :planning_kind),
         planning_phase_id: Map.get(payload, :planning_phase_id),
         trace_event_id: Map.get(payload, :trace_event_id)
       }, "task:#{task_id}"}
    else
      command_accepted("task.create", payload)
    end
  end

  defp domain_event("task.approve", payload),
    do: task_status_event("task.approve", payload, "ready")

  defp domain_event("task.block", payload),
    do: task_status_event("task.block", payload, "blocked")

  defp domain_event("task.close", payload), do: task_status_event("task.close", payload, "closed")

  defp domain_event("task.update", payload) do
    with {:ok, task_id} <- required_binary(Map.get(payload, :task_id), :task_id) do
      {:ok, "TaskUpdated", Map.put(payload, :task_id, task_id), "task:#{task_id}"}
    end
  end

  defp domain_event("run.fail", payload) do
    with {:ok, run_id} <- required_binary(Map.get(payload, :run_id), :run_id) do
      {:ok, "RunFailed", Map.put(payload, :run_id, run_id), "run:#{run_id}"}
    end
  end

  defp domain_event("task.annotate", payload) do
    with {:ok, task_id} <- required_binary(Map.get(payload, :task_id), :task_id),
         {:ok, body} <- required_binary(Map.get(payload, :body), :body) do
      {:ok, "TaskAnnotated", %{task_id: task_id, body: body, author: Map.get(payload, :author)},
       "task:#{task_id}"}
    end
  end

  defp domain_event("task.add_dependency", payload) do
    with {:ok, task_id} <- required_binary(Map.get(payload, :task_id), :task_id),
         {:ok, depends_on} <- required_binary(Map.get(payload, :depends_on), :depends_on) do
      {:ok, "TaskDependencyAdded", %{task_id: task_id, depends_on: depends_on}, "task:#{task_id}"}
    end
  end

  defp domain_event(command_type, command), do: command_accepted(command_type, command)

  defp command_accepted(command_type, command) do
    {:ok, "CommandAccepted",
     %{
       command_id: Map.get(command, :command_id),
       command_type: command_type,
       status: "accepted",
       input: command
     }, "command:#{Map.get(command, :command_id, command_type)}"}
  end

  defp maybe_schedule_dispatch(event_type, payload)
       when event_type in ["TaskCreated", "TaskUpdated"] do
    if Map.get(payload, :status) in ["ready", "approved"] do
      Task.start(fn ->
        Process.sleep(100)
        if Process.whereis(Scheduler), do: Scheduler.tick()
      end)
    end

    :ok
  end

  defp maybe_schedule_dispatch(_event_type, _payload), do: :ok

  defp maybe_audit(%{command_type: command_type} = command, event_type, payload) do
    if Security.destructive_command?(command_type) do
      Security.append_destructive_audit(command, event_type, payload)
    else
      {:ok, []}
    end
  end

  defp task_status_event(command_type, payload, status) do
    case Map.get(payload, :task_id) do
      task_id when is_binary(task_id) and task_id != "" ->
        {:ok, "TaskUpdated", %{task_id: task_id, status: status}, "task:#{task_id}"}

      _ ->
        command_accepted(command_type, payload)
    end
  end

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp handle_external_trigger(payload, metadata) do
    input = Map.put_new(payload, :correlation_id, Map.get(metadata, :correlation_id))

    with {:ok, result} <- IntegrationIngestion.ingest(input),
         {:ok, event} <- result_event(result) do
      {:ok, %{event: event, projection: ProjectionStore.snapshot(), integration: result}}
    end
  end

  defp result_event(%{ingestion: event}), do: {:ok, event}
  defp result_event(%{command: %{event: event}}), do: {:ok, event}

  defp result_event(%{existing: %{dedupe_key: dedupe_key}}) do
    case Enum.find(EventStore.all(), &(&1.stream_id == "integration:#{dedupe_key}")) do
      nil -> {:error, {:missing_integration_event, dedupe_key}}
      event -> {:ok, event}
    end
  end

  defp normalize_metadata(command) do
    metadata = normalize_payload(Map.get(command, :metadata, %{}))

    metadata
    |> Map.put_new(
      :correlation_id,
      Map.get(command, :correlation_id, Map.get(command, :command_id))
    )
    |> Map.put_new(:source, "node-cli-boundary")
    |> Map.put_new(:idempotency_key, Map.get(command, :command_id))
  end

  defp handle_planning_flow(payload, metadata) do
    input = Map.put_new(payload, :correlation_id, Map.get(metadata, :correlation_id))

    with {:ok, result} <- PlanningFlow.run(input) do
      {:ok, %{event: result.event, projection: ProjectionStore.snapshot(), planning: result}}
    end
  end

  defp handle_migration_import(payload, metadata) do
    input = Map.put_new(payload, :correlation_id, Map.get(metadata, :correlation_id))

    with {:ok, result} <- MigrationImporter.import(input) do
      {:ok, %{event: result.event, projection: ProjectionStore.snapshot(), migration: result}}
    end
  end

  defp planning_payload(command, command_type) do
    payload = external_trigger_payload(command)

    case command_type do
      "plan.prd" -> Map.put(payload, :kind, "prd")
      "plan.trd" -> Map.put(payload, :kind, "trd")
      _ -> payload
    end
  end

  defp migration_payload(command), do: external_trigger_payload(command)

  defp external_trigger_payload(command) do
    top_level =
      command
      |> normalize_payload()
      |> Map.drop([:command_id, :command_type, :correlation_id, :metadata])

    nested = normalize_payload(Map.get(command, :payload, %{}))

    if map_size(nested) == 0 do
      top_level
    else
      command
      |> Map.has_key?(:command_id)
      |> case do
        true -> top_level |> Map.drop([:payload]) |> Map.merge(nested)
        false -> Map.merge(top_level, nested)
      end
    end
  end

  defp external_command_id(command) do
    normalized = normalize_payload(command)

    Enum.find_value(
      [:command_id, :idempotency_key, :dedupe_key, :event_id, :external_id],
      fn key ->
        value = Map.get(normalized, key)
        if is_binary(value) and value != "", do: value
      end
    ) || "external-trigger:#{System.unique_integer([:positive])}"
  end

  defp normalize_payload(map) when is_map(map) do
    Enum.reduce(known_keys(), %{}, fn key, acc ->
      case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp normalize_payload(_), do: %{}

  defp known_keys do
    [
      :author,
      :body,
      :command_id,
      :config,
      :correlation_id,
      :count,
      :create_prd_command,
      :dedupe_key,
      :default_branch,
      :dependencies,
      :description,
      :depends_on,
      :event_id,
      :event_type,
      :external_id,
      :external_link,
      :fingerprint,
      :health,
      :id,
      :inbox_messages,
      :input,
      :kind,
      :idempotency_key,
      :integration_event_type,
      :metadata,
      :migration_id,
      :actor,
      :occurred_at,
      :output_dir,
      :path,
      :payload,
      :plan_type,
      :planning_kind,
      :planning_phase_id,
      :planning_run_id,
      :project_id,
      :projects,
      :repo,
      :run_id,
      :runs,
      :severity,
      :site,
      :source,
      :status,
      :task_id,
      :task_type,
      :threshold,
      :title,
      :trace_event_id,
      :priority,
      :task_type,
      :type,
      :transition_id,
      :url,
      :workflows,
      :adapter,
      :compatibility_mode,
      :from_prd,
      :provider
    ]
  end
end
