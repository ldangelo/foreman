defmodule ForemanServer.Http.Router do
  @moduledoc "Authenticated JSON HTTP API for the Foreman Elixir server."

  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  get "/api/v1/health" do
    send_json(conn, 200, %{ok: true, active_projects: ForemanServer.active_projects()})
  end

  get "/api/v1/projects" do
    with :ok <- authorize(conn) do
      send_json(conn, 200, %{ok: true, projects: ForemanServer.ProjectionStore.project_list()})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
  end

  get "/api/v1/projects/:project_id" do
    with :ok <- authorize(conn),
         project when not is_nil(project) <- ForemanServer.ProjectionStore.project(project_id) do
      send_json(conn, 200, %{ok: true, project: project})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      nil ->
        send_error(conn, 404, "NOT_FOUND", "project not found", false)
    end
  end

  get "/api/v1/tasks" do
    with :ok <- authorize(conn) do
      send_json(conn, 200, %{ok: true, tasks: ForemanServer.ProjectionStore.task_list()})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
  end

  get "/api/v1/tasks/dispatchable" do
    with :ok <- authorize(conn) do
      send_json(conn, 200, %{ok: true, tasks: ForemanServer.ProjectionStore.dispatchable_tasks()})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
  end

  get "/api/v1/tasks/:task_id" do
    with :ok <- authorize(conn),
         task when not is_nil(task) <- ForemanServer.ProjectionStore.task(task_id) do
      send_json(conn, 200, %{ok: true, task: task})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      nil ->
        send_error(conn, 404, "NOT_FOUND", "task not found", false)
    end
  end

  get "/api/v1/runs/:run_id/logs" do
    conn = fetch_query_params(conn)

    with :ok <- authorize(conn),
         {:ok, mode} <- log_view_mode(conn.query_params["view"]),
         {:ok, logs} <- ForemanServer.DebugViews.logs(run_id, mode: mode) do
      send_json(conn, 200, %{ok: true, logs: logs})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)
    end
  end

  get "/api/v1/runs/:run_id/report" do
    with :ok <- authorize(conn),
         {:ok, report} <- ForemanServer.DebugViews.report(run_id) do
      send_json(conn, 200, %{ok: true, report: report})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)
    end
  end

  get "/api/v1/runs/:run_id/debug" do
    with :ok <- authorize(conn),
         {:ok, debug} <- ForemanServer.DebugViews.debug_timeline(run_id) do
      send_json(conn, 200, %{ok: true, debug: debug})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)
    end
  end

  get "/api/v1/runs/:run_id/attach" do
    conn = fetch_query_params(conn)

    with :ok <- authorize(conn),
         {:ok, %{result: result}} <-
           ForemanServer.AttachBridge.request_attach(%{
             run_id: run_id,
             worker_id: conn.query_params["worker_id"]
           }) do
      send_json(conn, 200, %{ok: true, attach: result})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)

      {:error, {:not_found, :run}} ->
        send_error(conn, 404, "NOT_FOUND", "run not found", false)

      {:error, {:conflict, reason}} ->
        send_error(conn, 409, "CONFLICT", inspect(reason), false)
    end
  end

  post "/api/v1/runs/:run_id/interrupt" do
    with :ok <- authorize(conn),
         {:ok, %{result: result}} <-
           ForemanServer.AttachBridge.interrupt_phase(Map.put(conn.body_params, "run_id", run_id)) do
      send_json(conn, 202, %{ok: true, interruption: result})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)

      {:error, {:not_found, :run}} ->
        send_error(conn, 404, "NOT_FOUND", "run not found", false)

      {:error, {:not_found, :phase}} ->
        send_error(conn, 404, "NOT_FOUND", "phase not found", false)

      {:error, {:conflict, reason}} ->
        send_error(conn, 409, "CONFLICT", inspect(reason), false)
    end
  end

  post "/api/v1/runs/:run_id/resume" do
    with :ok <- authorize(conn),
         {:ok, %{result: result}} <-
           ForemanServer.AttachBridge.resume_after_interrupt(
             Map.put(conn.body_params, "run_id", run_id)
           ) do
      send_json(conn, 202, %{ok: true, recovery: result})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)

      {:error, {:not_found, :run}} ->
        send_error(conn, 404, "NOT_FOUND", "run not found", false)

      {:error, {:not_found, :phase}} ->
        send_error(conn, 404, "NOT_FOUND", "phase not found", false)

      {:error, {:conflict, reason}} ->
        send_error(conn, 409, "CONFLICT", inspect(reason), false)
    end
  end

  post "/worker/v1/phases/:phase_id/start" do
    with :ok <- authorize(conn),
         {:ok, %{event: event, projection: projection}} <-
           ForemanServer.WorkerProtocol.start_phase(phase_id, conn.body_params) do
      send_json(conn, 202, %{
        ok: true,
        events: [event.event_id],
        projection_version: projection.last_sequence,
        correlation_id: event.correlation_id
      })
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)

      {:error, {code, value, message}}
      when code in [:unsupported_provider, :adapter_not_production_ready] ->
        send_error(conn, 400, "VALIDATION_FAILED", message, false, %{provider: value})

      {:error, {:unsupported_tools, tools, message}} ->
        send_error(conn, 400, "VALIDATION_FAILED", message, false, %{unsupported_tools: tools})

      {:error, reason} ->
        send_error(conn, 500, "INTERNAL", inspect(reason), true)
    end
  end

  post "/worker/v1/heartbeat" do
    with :ok <- authorize(conn),
         {:ok, %{event: event, projection: projection}} <-
           ForemanServer.WorkerProtocol.heartbeat(conn.body_params) do
      send_json(conn, 202, %{
        ok: true,
        events: [event.event_id],
        projection_version: projection.last_sequence,
        correlation_id: event.correlation_id
      })
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)

      {:error, reason} ->
        send_error(conn, 500, "INTERNAL", inspect(reason), true)
    end
  end

  post "/worker/v1/events" do
    with :ok <- authorize(conn),
         {:ok, %{event: event, projection: projection}} <-
           ForemanServer.WorkerProtocol.ingest_event(conn.body_params) do
      send_json(conn, 202, %{
        ok: true,
        events: [event.event_id],
        projection_version: projection.last_sequence,
        correlation_id: event.correlation_id
      })
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)

      {:error, {:out_of_order_sequence, details}} ->
        send_error(conn, 409, "CONFLICT", "out-of-order worker sequence", false, Map.new(details))

      {:error, reason} ->
        send_error(conn, 500, "INTERNAL", inspect(reason), true)
    end
  end

  post "/api/v1/commands" do
    with :ok <- authorize(conn),
         {:ok, command} <- normalize_command(conn.body_params),
         {:ok, %{event: event, projection: projection}} <- ForemanServer.handle_command(command) do
      send_json(conn, 202, %{
        ok: true,
        events: [event.event_id],
        projection_version: projection.last_sequence,
        correlation_id: event.correlation_id
      })
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, :invalid_command} ->
        send_error(conn, 400, "VALIDATION_FAILED", "invalid command envelope", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)

      {:error, {:conflict, details}} ->
        send_error(conn, 409, "CONFLICT", "stream version conflict", false, Map.new(details))

      {:error, reason} ->
        send_error(conn, 500, "INTERNAL", inspect(reason), true)
    end
  end

  match _ do
    send_error(conn, 404, "UNSUPPORTED", "route not found", false)
  end

  defp log_view_mode(nil), do: {:ok, :compact}
  defp log_view_mode(""), do: {:ok, :compact}
  defp log_view_mode("compact"), do: {:ok, :compact}
  defp log_view_mode("raw"), do: {:ok, :raw}
  defp log_view_mode(_view), do: {:error, {:missing_or_invalid, :view}}

  defp authorize(conn) do
    expected =
      Application.get_env(:foreman_server, :auth_token) ||
        System.get_env("FOREMAN_SERVER_AUTH_TOKEN")

    cond do
      is_nil(expected) or expected == "" -> :ok
      get_req_header(conn, "authorization") == ["Bearer #{expected}"] -> :ok
      true -> {:error, :unauthorized}
    end
  end

  defp normalize_command(%{"command_type" => command_type} = params)
       when command_type in [
              "ExternalTriggerCommand",
              "external.trigger",
              "PlanningFlowCommand",
              "plan.prd",
              "plan.trd",
              "MigrationImportCommand",
              "migration.import"
            ] do
    {:ok, params}
  end

  defp normalize_command(%{"command_id" => command_id, "command_type" => command_type} = params)
       when is_binary(command_id) and is_binary(command_type) do
    {:ok,
     %{
       command_id: command_id,
       command_type: command_type,
       correlation_id: get_in(params, ["metadata", "correlation_id"]),
       payload: Map.get(params, "payload", %{}),
       metadata: Map.get(params, "metadata", %{})
     }}
  end

  defp normalize_command(_), do: {:error, :invalid_command}

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end

  defp send_error(conn, status, code, message, retryable, details \\ %{}) do
    send_json(conn, status, %{
      ok: false,
      error: %{
        code: code,
        message: message,
        details: details,
        retryable: retryable,
        correlation_id: List.first(get_req_header(conn, "x-correlation-id"))
      }
    })
  end
end
