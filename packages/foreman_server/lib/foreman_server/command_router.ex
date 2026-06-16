defmodule ForemanServer.CommandRouter do
  @moduledoc "Command boundary for server-side project/task mutations."

  alias ForemanServer.{EventStore, IntegrationIngestion, ProjectionStore}

  @spec handle(map()) :: {:ok, map()} | {:error, term()}
  def handle(%{"command_id" => command_id, "command_type" => command_type} = command) do
    handle(%{
      command_id: command_id,
      command_type: command_type,
      correlation_id: Map.get(command, "correlation_id"),
      payload: Map.get(command, "payload", %{}),
      metadata: Map.get(command, "metadata", %{})
    })
  end

  def handle(%{command_id: command_id, command_type: command_type} = command)
      when is_binary(command_id) and is_binary(command_type) do
    payload =
      command
      |> Map.get(:payload, %{})
      |> normalize_payload()
      |> Map.put_new(:command_id, command_id)

    metadata = normalize_metadata(command)

    case command_type do
      "ExternalTriggerCommand" ->
        handle_external_trigger(payload, metadata)

      "external.trigger" ->
        handle_external_trigger(payload, metadata)

      _ ->
        with {:ok, event_type, event_payload, stream_id} <- domain_event(command_type, payload),
             {:ok, event} <-
               EventStore.append(%{
                 stream_id: stream_id,
                 event_type: event_type,
                 payload:
                   event_payload
                   |> Map.put_new(:command_id, command_id)
                   |> Map.put_new(:updated_at, DateTime.utc_now()),
                 metadata: metadata,
                 correlation_id: Map.get(metadata, :correlation_id)
               }) do
          {:ok, %{event: event, projection: ProjectionStore.snapshot()}}
        end
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
         status: Map.get(payload, :status, "open"),
         dependencies: Map.get(payload, :dependencies, []),
         task_type: Map.get(payload, :task_type),
         source: Map.get(payload, :source),
         external_id: Map.get(payload, :external_id),
         external_link: Map.get(payload, :external_link),
         dedupe_key: Map.get(payload, :dedupe_key),
         integration_event_type: Map.get(payload, :integration_event_type)
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
      :dedupe_key,
      :default_branch,
      :dependencies,
      :depends_on,
      :event_id,
      :event_type,
      :external_id,
      :external_link,
      :fingerprint,
      :health,
      :id,
      :idempotency_key,
      :integration_event_type,
      :metadata,
      :occurred_at,
      :path,
      :payload,
      :project_id,
      :repo,
      :severity,
      :site,
      :source,
      :status,
      :task_id,
      :task_type,
      :threshold,
      :title,
      :transition_id,
      :url
    ]
  end
end
