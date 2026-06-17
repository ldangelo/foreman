defmodule ForemanServer.MigrationImporter do
  @moduledoc """
  Imports TypeScript-era Foreman state into the Elixir event store.

  The importer intentionally maps legacy records into existing domain events where
  possible so migrated projects, tasks, runs, and inbox messages remain readable
  through the normal projections. Configuration and workflow records are retained
  as migration records until dedicated first-class projections exist.
  """

  alias ForemanServer.EventStore

  @spec import(map()) :: {:ok, map()} | {:error, term()}
  def import(input) when is_map(input) do
    with {:ok, normalized} <- validate_input(input),
         {:ok, migration_id} <-
           required_binary(Map.get(normalized, :migration_id), :migration_id),
         {:ok, source} <- required_binary(Map.get(normalized, :source), :source) do
      case existing_completed_import(migration_id) do
        nil -> execute_import(normalized, migration_id, source)
        completed -> {:ok, existing_result(completed)}
      end
    end
  end

  def import(_input), do: {:error, {:missing_or_invalid, :payload}}

  defp execute_import(input, migration_id, source) do
    metadata = %{
      source: "migration-importer",
      idempotency_key: migration_id,
      correlation_id: Map.get(input, :correlation_id, migration_id)
    }

    with {:ok, started} <-
           append(
             "MigrationImportStarted",
             "migration:#{migration_id}",
             %{
               migration_id: migration_id,
               source: source,
               status: "in_progress",
               started_at: now()
             },
             item_metadata(metadata, "migration", migration_id, "started")
           ),
         {:ok, project_events} <- import_projects(input, migration_id, metadata),
         {:ok, workflow_events} <-
           import_records(input, migration_id, :workflows, "workflow", metadata),
         {:ok, config_events} <- import_config(input, migration_id, metadata),
         {:ok, task_events} <- import_tasks(input, migration_id, metadata),
         {:ok, run_events} <- import_runs(input, migration_id, metadata),
         {:ok, inbox_events} <- import_inbox(input, migration_id, metadata),
         summary = %{
           projects: length(project_events),
           tasks: length(task_events),
           runs: count_runs(input),
           workflows: length(workflow_events),
           inbox_messages: length(inbox_events),
           config: length(config_events)
         },
         {:ok, completed} <-
           append(
             "MigrationImportCompleted",
             "migration:#{migration_id}",
             %{
               migration_id: migration_id,
               source: source,
               status: "completed",
               summary: summary,
               completed_at: now()
             },
             item_metadata(metadata, "migration", migration_id, "completed")
           ) do
      {:ok,
       %{
         migration_id: migration_id,
         status: "completed",
         existing: false,
         event: completed,
         started_event: started,
         imported: summary,
         events:
           [started] ++
             project_events ++
             workflow_events ++
             config_events ++
             task_events ++
             run_events ++
             inbox_events ++ [completed]
       }}
    end
  end

  defp import_projects(input, migration_id, metadata) do
    input
    |> Map.get(:projects, [])
    |> map_events(fn project, index ->
      with {:ok, project_id} <-
             required_binary(Map.get(project, :project_id) || Map.get(project, :id), :project_id),
           {:ok, path} <- required_binary(Map.get(project, :path), :path) do
        append(
          "ProjectRegistered",
          "project:#{project_id}",
          %{
            migration_id: migration_id,
            legacy_id: Map.get(project, :legacy_id, project_id),
            project_id: project_id,
            path: path,
            status: Map.get(project, :status, "active"),
            default_branch: Map.get(project, :default_branch, "main"),
            config: Map.get(project, :config, %{}),
            health: Map.get(project, :health, %{ok: true}),
            imported_at: now(),
            import_index: index
          },
          item_metadata(metadata, "project", project_id)
        )
      end
    end)
  end

  defp import_tasks(input, migration_id, metadata) do
    input
    |> Map.get(:tasks, [])
    |> map_events(fn task, index ->
      with {:ok, task_id} <-
             required_binary(Map.get(task, :task_id) || Map.get(task, :id), :task_id) do
        append(
          "TaskCreated",
          "task:#{task_id}",
          %{
            migration_id: migration_id,
            legacy_id: Map.get(task, :legacy_id, task_id),
            task_id: task_id,
            project_id: Map.get(task, :project_id),
            title: Map.get(task, :title, task_id),
            status: Map.get(task, :status, "open"),
            dependencies: Map.get(task, :dependencies, []),
            task_type: Map.get(task, :task_type, Map.get(task, :type)),
            source: Map.get(task, :source, "legacy-ts"),
            external_id: Map.get(task, :external_id, task_id),
            imported_at: now(),
            import_index: index
          },
          item_metadata(metadata, "task", task_id)
        )
      end
    end)
  end

  defp import_runs(input, migration_id, metadata) do
    input
    |> Map.get(:runs, [])
    |> map_events(fn run, index ->
      with {:ok, run_id} <- required_binary(Map.get(run, :run_id) || Map.get(run, :id), :run_id) do
        phase_order = Map.get(run, :phase_order, [])
        current_phase = Map.get(run, :current_phase) || List.first(phase_order)
        status = Map.get(run, :status, "completed")

        started_payload = %{
          migration_id: migration_id,
          legacy_id: Map.get(run, :legacy_id, run_id),
          run_id: run_id,
          task_id: Map.get(run, :task_id),
          phase_order: phase_order,
          current_phase: current_phase,
          imported_at: now(),
          import_index: index
        }

        with {:ok, started} <-
               append(
                 "RunStarted",
                 "run:#{run_id}",
                 started_payload,
                 item_metadata(metadata, "run", run_id, "started")
               ),
             {:ok, terminal} <-
               append_terminal_run(run_id, status, run, current_phase, migration_id, metadata) do
          {:ok, [started, terminal]}
        end
      end
    end)
    |> case do
      {:ok, nested} -> {:ok, List.flatten(nested)}
      error -> error
    end
  end

  defp append_terminal_run(run_id, "failed", run, current_phase, migration_id, metadata) do
    append(
      "RunFailed",
      "run:#{run_id}",
      %{
        migration_id: migration_id,
        run_id: run_id,
        phase_id: current_phase,
        retry_history: Map.get(run, :retry_history, []),
        imported_at: now()
      },
      item_metadata(metadata, "run", run_id, "failed")
    )
  end

  defp append_terminal_run(run_id, "blocked", _run, _current_phase, migration_id, metadata) do
    append(
      "RunBlocked",
      "run:#{run_id}",
      %{migration_id: migration_id, run_id: run_id, imported_at: now()},
      item_metadata(metadata, "run", run_id, "blocked")
    )
  end

  defp append_terminal_run(run_id, "completed", _run, _current_phase, migration_id, metadata) do
    append(
      "RunCompleted",
      "run:#{run_id}",
      %{migration_id: migration_id, run_id: run_id, imported_at: now()},
      item_metadata(metadata, "run", run_id, "completed")
    )
  end

  defp import_inbox(input, migration_id, metadata) do
    input
    |> Map.get(:inbox_messages, [])
    |> map_events(fn message, index ->
      with {:ok, message_id} <-
             required_binary(Map.get(message, :message_id) || Map.get(message, :id), :message_id),
           {:ok, run_id} <- required_binary(Map.get(message, :run_id), :run_id) do
        append(
          "InboxMessageAppended",
          "inbox:#{message_id}",
          %{
            migration_id: migration_id,
            message_id: message_id,
            run_id: run_id,
            phase_id: Map.get(message, :phase_id),
            sender: Map.get(message, :sender, "legacy-ts"),
            recipient: Map.get(message, :recipient, "operator"),
            body: Map.get(message, :body, Map.get(message, :message, "")),
            status: Map.get(message, :status, "delivered"),
            imported_at: now(),
            import_index: index
          },
          item_metadata(metadata, "inbox", message_id)
        )
      end
    end)
  end

  defp import_records(input, migration_id, field, record_type, metadata) do
    input
    |> Map.get(field, [])
    |> map_events(fn record, index ->
      with {:ok, record_id} <-
             required_binary(
               Map.get(record, :id) || Map.get(record, :name),
               String.to_atom("#{record_type}_id")
             ) do
        append(
          "MigrationRecordImported",
          "migration:#{migration_id}:#{record_type}:#{record_id}",
          %{
            migration_id: migration_id,
            record_type: record_type,
            record_id: record_id,
            data: record,
            imported_at: now(),
            import_index: index
          },
          item_metadata(metadata, record_type, record_id)
        )
      end
    end)
  end

  defp import_config(input, migration_id, metadata) do
    case Map.get(input, :config, %{}) do
      config when is_map(config) and map_size(config) > 0 ->
        append(
          "MigrationRecordImported",
          "migration:#{migration_id}:config",
          %{
            migration_id: migration_id,
            record_type: "config",
            record_id: "config",
            data: config,
            imported_at: now(),
            import_index: 0
          },
          item_metadata(metadata, "config", "config")
        )
        |> case do
          {:ok, event} -> {:ok, [event]}
          error -> error
        end

      config when is_map(config) ->
        {:ok, []}
    end
  end

  defp validate_input(input) do
    normalized = normalize(input)

    with {:ok, _migration_id} <-
           required_binary(Map.get(normalized, :migration_id), :migration_id),
         {:ok, _source} <- required_binary(Map.get(normalized, :source), :source),
         {:ok, projects} <- normalized_record_list(normalized, :projects),
         {:ok, tasks} <- normalized_record_list(normalized, :tasks),
         {:ok, runs} <- normalized_record_list(normalized, :runs),
         {:ok, workflows} <- normalized_record_list(normalized, :workflows),
         {:ok, inbox_messages} <- normalized_record_list(normalized, :inbox_messages),
         {:ok, config} <- normalized_config(normalized),
         :ok <- validate_projects(projects),
         :ok <- validate_tasks(tasks),
         :ok <- validate_runs(runs),
         :ok <- validate_workflows(workflows),
         :ok <- validate_inbox_messages(inbox_messages),
         :ok <- reject_duplicate_ids(:projects, projects, &record_id(&1, [:project_id, :id])),
         :ok <- reject_duplicate_ids(:tasks, tasks, &record_id(&1, [:task_id, :id])),
         :ok <- reject_duplicate_ids(:runs, runs, &record_id(&1, [:run_id, :id])),
         :ok <- reject_duplicate_ids(:workflows, workflows, &record_id(&1, [:id, :name])),
         :ok <-
           reject_duplicate_ids(
             :inbox_messages,
             inbox_messages,
             &record_id(&1, [:message_id, :id])
           ) do
      {:ok,
       normalized
       |> Map.put(:projects, projects)
       |> Map.put(:tasks, tasks)
       |> Map.put(:runs, runs)
       |> Map.put(:workflows, workflows)
       |> Map.put(:inbox_messages, inbox_messages)
       |> Map.put(:config, config)}
    end
  end

  defp normalized_record_list(input, key) do
    case Map.get(input, key, []) do
      records when is_list(records) ->
        records
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {record, index}, {:ok, acc} ->
          if is_map(record) do
            {:cont, {:ok, acc ++ [normalize(record)]}}
          else
            {:halt, {:error, {:missing_or_invalid, {key, index}}}}
          end
        end)

      _ ->
        {:error, {:missing_or_invalid, key}}
    end
  end

  defp normalized_config(input) do
    case Map.get(input, :config, %{}) do
      config when is_map(config) -> {:ok, config}
      _ -> {:error, {:missing_or_invalid, :config}}
    end
  end

  defp validate_projects(projects) do
    require_each(projects, fn project ->
      with {:ok, _project_id} <-
             required_binary(record_id(project, [:project_id, :id]), :project_id),
           {:ok, _path} <- required_binary(Map.get(project, :path), :path) do
        :ok
      end
    end)
  end

  defp validate_tasks(tasks) do
    require_each(tasks, fn task ->
      with {:ok, _task_id} <- required_binary(record_id(task, [:task_id, :id]), :task_id) do
        :ok
      end
    end)
  end

  defp validate_runs(runs) do
    require_each(runs, fn run ->
      with {:ok, _run_id} <- required_binary(record_id(run, [:run_id, :id]), :run_id),
           :ok <- validate_run_status(Map.get(run, :status, "completed")),
           :ok <- validate_optional_binary(run, :current_phase),
           :ok <- validate_optional_binary_list(run, :phase_order),
           :ok <- validate_optional_list(run, :retry_history) do
        :ok
      end
    end)
  end

  defp validate_workflows(workflows) do
    require_each(workflows, fn workflow ->
      with {:ok, _workflow_id} <- required_binary(record_id(workflow, [:id, :name]), :workflow_id) do
        :ok
      end
    end)
  end

  defp validate_inbox_messages(messages) do
    require_each(messages, fn message ->
      with {:ok, _message_id} <-
             required_binary(record_id(message, [:message_id, :id]), :message_id),
           {:ok, _run_id} <- required_binary(Map.get(message, :run_id), :run_id) do
        :ok
      end
    end)
  end

  defp validate_run_status(status) when status in ["completed", "failed", "blocked"], do: :ok
  defp validate_run_status(_status), do: {:error, {:invalid_status, :runs}}

  defp validate_optional_binary(record, key) do
    case Map.get(record, key) do
      nil -> :ok
      value when is_binary(value) -> :ok
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp validate_optional_list(record, key) do
    case Map.get(record, key) do
      nil -> :ok
      value when is_list(value) -> :ok
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp validate_optional_binary_list(record, key) do
    case Map.get(record, key) do
      nil -> :ok
      value when is_list(value) -> validate_binary_list(value, key)
      _ -> {:error, {:missing_or_invalid, key}}
    end
  end

  defp validate_binary_list(values, key) do
    if Enum.all?(values, &is_binary/1) do
      :ok
    else
      {:error, {:missing_or_invalid, key}}
    end
  end

  defp require_each(records, fun) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case fun.(record) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reject_duplicate_ids(field, records, id_fun) do
    records
    |> Enum.map(id_fun)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.find(fn {_id, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {id, _count} -> {:error, {:duplicate_id, field, id}}
    end
  end

  defp record_id(record, keys) do
    Enum.find_value(keys, &Map.get(record, &1))
  end

  defp map_events(records, fun) when is_list(records) do
    records
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {record, index}, {:ok, events} ->
      case fun.(normalize(record), index) do
        {:ok, event_or_events} -> {:cont, {:ok, events ++ List.wrap(event_or_events)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append(type, stream_id, payload, metadata) do
    EventStore.append(%{
      stream_id: stream_id,
      event_type: type,
      payload: payload,
      metadata: metadata,
      correlation_id: Map.get(metadata, :correlation_id)
    })
  end

  defp existing_completed_import(migration_id) do
    EventStore.stream("migration:#{migration_id}")
    |> Enum.find(&(&1.event_type == "MigrationImportCompleted"))
  end

  defp existing_result(event) do
    %{
      migration_id: event.payload.migration_id,
      status: "completed",
      existing: true,
      event: event,
      imported: Map.get(event.payload, :summary, %{}),
      events: [event]
    }
  end

  defp item_metadata(metadata, type, id, suffix \\ nil) do
    key = [metadata.idempotency_key, type, id, suffix] |> Enum.reject(&is_nil/1) |> Enum.join(":")
    %{metadata | idempotency_key: key}
  end

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp normalize(map) when is_map(map) do
    Enum.reduce(known_record_keys(), %{}, fn key, acc ->
      value = Map.get(map, key) || Map.get(map, Atom.to_string(key))
      if is_nil(value), do: acc, else: Map.put(acc, key, value)
    end)
  end

  defp normalize(other), do: other

  defp known_record_keys do
    [
      :body,
      :command_id,
      :config,
      :correlation_id,
      :current_phase,
      :data,
      :default_branch,
      :dependencies,
      :external_id,
      :health,
      :id,
      :legacy_id,
      :message,
      :message_id,
      :migration_id,
      :name,
      :path,
      :phase_id,
      :phase_order,
      :project_id,
      :projects,
      :recipient,
      :retry_history,
      :run_id,
      :runs,
      :sender,
      :source,
      :status,
      :task_id,
      :task_type,
      :tasks,
      :title,
      :type,
      :workflows,
      :inbox_messages
    ]
  end

  defp count_runs(input), do: input |> Map.get(:runs, []) |> length()
  defp now, do: DateTime.utc_now()
end
