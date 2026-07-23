defmodule ForemanServer.Http.Router do
  @moduledoc "Authenticated JSON HTTP API for the Foreman Elixir server."

  use Plug.Router

  # NOTE: Plug.Parsers is conditionally applied below to preserve the raw body
  # for /webhooks/github HMAC verification.
  plug(:match)
  plug(:maybe_parse_body)
  plug(:dispatch)

  # Conditionally apply Plug.Parsers for all routes EXCEPT /webhooks/github.
  # The webhook route needs the raw request body for HMAC-SHA256 verification.
  defp maybe_parse_body(%Plug.Conn{path_info: ["webhooks", "github" | _]} = conn, _opts),
    do: conn

  defp maybe_parse_body(conn, _opts) do
    Plug.Parsers.call(conn, Plug.Parsers.init(
      parsers: [:json],
      pass: ["application/json"],
      json_decoder: Jason
    ))
  end

  get "/api/v1/health" do
    payload = %{
      ok: true,
      active_projects: ForemanServer.active_projects()
    }

    payload =
      case authorize(conn) do
        :ok -> Map.put(payload, :runtime, ForemanServer.RuntimeInfo.identity())
        {:error, :unauthorized} -> payload
      end

    send_json(conn, 200, payload)
  end

  get "/api/v1/doctor" do
    with :ok <- authorize(conn),
         {:ok, doctor} <- ForemanServer.Operations.doctor() do
      send_json(conn, if(doctor.ok, do: 200, else: 503), %{ok: doctor.ok, doctor: doctor})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
  end

  get "/api/v1/metrics" do
    with :ok <- authorize(conn),
         {:ok, metrics} <- ForemanServer.Operations.metrics() do
      send_json(conn, 200, %{ok: true, metrics: metrics})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
  end

  get "/api/v1/scheduler" do
    with :ok <- authorize(conn) do
      send_json(conn, 200, %{ok: true, scheduler: ForemanServer.Scheduler.state()})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
  end

  post "/api/v1/scheduler/tick" do
    with :ok <- authorize(conn),
         {:ok, result} <- ForemanServer.scheduler_tick() do
      send_json(conn, 202, %{ok: true, scheduler: result})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
  end

  post "/api/v1/projections/rebuild" do
    with :ok <- authorize(conn),
         {:ok, projection} <- ForemanServer.EventStore.rebuild_projections() do
      send_json(conn, 202, %{
        ok: true,
        checkpoint: Map.get(projection, :checkpoint),
        projects: map_size(Map.get(projection, :projects, %{})),
        tasks: map_size(Map.get(projection, :tasks, %{})),
        runs: map_size(Map.get(projection, :runs, %{})),
        inbox_messages: map_size(Map.get(projection, :inbox_messages, %{}))
      })
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
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
    conn = fetch_query_params(conn)

    with :ok <- authorize(conn) do
      since = conn.query_params["since"]

      tasks =
        ForemanServer.ProjectionStore.task_list()
        |> maybe_filter_tasks_since(since)

      send_json(conn, 200, %{ok: true, tasks: tasks})
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
  get "/api/v1/board" do
    conn = fetch_query_params(conn)

    with :ok <- authorize(conn),
         project_id when not is_nil(project_id) and project_id != "" <- conn.query_params["project_id"] do
      board = ForemanServer.ProjectionStore.board(project_id)
      send_json(conn, 200, %{ok: true, project_id: project_id, columns: board})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      nil ->
        send_error(conn, 400, "BAD_REQUEST", "project_id query parameter is required", false)
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

  get "/api/v1/runs" do
    conn = fetch_query_params(conn)

    with :ok <- authorize(conn) do
      snapshot = ForemanServer.ProjectionStore.snapshot()
      project_id = conn.query_params["project_id"]
      event_summaries = run_event_summaries()
      pr_gates_by_run = pr_gates_by_run(snapshot)

      runs =
        snapshot.runs
        |> Map.values()
        |> Enum.map(fn run ->
          run
          |> Map.put(
            :project_id,
            get_in(snapshot, [:tasks, Map.get(run, :task_id), :project_id])
          )
          |> add_worktree_metadata(snapshot)
          |> add_run_metadata(snapshot, event_summaries, pr_gates_by_run)
        end)
        |> Enum.filter(fn run ->
          is_nil(project_id) or Map.get(run, :project_id) == project_id
        end)
        |> Enum.sort_by(& &1.run_id)

      send_json(conn, 200, %{ok: true, runs: runs})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
  end

  get "/api/v1/inbox" do
    conn = fetch_query_params(conn)

    with :ok <- authorize(conn) do
      snapshot = ForemanServer.ProjectionStore.snapshot()
      run_id = conn.query_params["run_id"]
      project_id = conn.query_params["project_id"]
      unread = conn.query_params["unread"]
      limit = query_limit(conn.query_params["limit"], 50)

      inbox =
        snapshot.inbox_messages
        |> Map.values()
        |> Enum.map(fn message ->
          run = get_in(snapshot, [:runs, Map.get(message, :run_id)])
          task_id = Map.get(message, :task_id) || Map.get(run || %{}, :task_id)

          message
          |> Map.put_new(:task_id, task_id)
          |> Map.put(:project_id, get_in(snapshot, [:tasks, task_id, :project_id]))
        end)
        |> Enum.filter(fn message -> is_nil(run_id) or Map.get(message, :run_id) == run_id end)
        |> Enum.filter(fn message ->
          is_nil(project_id) or Map.get(message, :project_id) == project_id
        end)
        |> Enum.filter(fn message ->
          unread != "true" or Map.get(message, :read_at) in [nil, ""]
        end)
        |> Enum.sort_by(&message_timestamp_sort_value/1, :asc)
        |> Enum.take(-limit)

      send_json(conn, 200, %{ok: true, inbox: inbox})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
  end

  get "/api/v1/events" do
    conn = fetch_query_params(conn)

    with :ok <- authorize(conn) do
      snapshot = ForemanServer.ProjectionStore.snapshot()
      run_id = conn.query_params["run_id"]
      project_id = conn.query_params["project_id"]
      limit = query_limit(conn.query_params["limit"], 50)

      events =
        ForemanServer.EventStore.all()
        |> Enum.map(&ForemanServer.Event.to_map/1)
        |> Enum.map(fn event ->
          event_run_id = get_in(event, [:payload, :run_id])

          event_task_id =
            get_in(event, [:payload, :task_id]) ||
              get_in(snapshot, [:runs, event_run_id, :task_id])

          event
          |> Map.put(:run_id, event_run_id)
          |> Map.put(:task_id, event_task_id)
          |> Map.put(:project_id, get_in(snapshot, [:tasks, event_task_id, :project_id]))
        end)
        |> Enum.filter(fn event -> is_nil(run_id) or Map.get(event, :run_id) == run_id end)
        |> Enum.filter(fn event ->
          is_nil(project_id) or Map.get(event, :project_id) == project_id
        end)
        |> Enum.sort_by(&event_timestamp_sort_value(Map.get(&1, :occurred_at)), :desc)
        |> Enum.take(limit)

      send_json(conn, 200, %{ok: true, events: events})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)
    end
  end

  get "/api/v1/runs/:run_id/logs" do
    conn = fetch_query_params(conn)

    with :ok <- authorize(conn),
         {:ok, mode} <- log_view_mode(conn.query_params["view"]),
         limit <- query_limit(conn.query_params["limit"], :unlimited),
         {:ok, logs} <- ForemanServer.DebugViews.logs(run_id, mode: mode, limit: limit) do
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

  post "/worker/v1/tool-policy" do
    with :ok <- authorize(conn),
         {:ok, decision} <- ForemanServer.Overwatch.check_tool(conn.body_params) do
      send_json(conn, 200, %{ok: true, decision: decision})
    else
      {:error, :unauthorized} ->
        send_error(conn, 401, "UNAUTHORIZED", "missing or invalid authorization", false)

      {:error, {:missing_or_invalid, key}} ->
        send_error(conn, 400, "VALIDATION_FAILED", "missing or invalid #{key}", false)

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

  post "/webhooks/github" do
    # Read raw body for HMAC-SHA256 verification before any parsing.
    # Plug.Parsers is skipped for this route (see maybe_parse_body/2).
    case read_raw_body(conn) do
      {:ok, raw_body, _conn} ->
        handle_github_webhook(conn, raw_body)

      {:error, reason} ->
        send_error(conn, 400, "BAD_REQUEST", "could not read request body: #{inspect(reason)}", false)
    end
  end

  match _ do
    send_error(conn, 404, "UNSUPPORTED", "route not found", false)
  end

  # Read the raw body from the connection for webhook HMAC verification.
  # Uses the adapter's read_body when available, with fallback to Plug.Conn.read_body/1.
  defp read_raw_body(conn) do
    case get_in(conn.private, [:raw_body]) do
      nil ->
        Plug.Conn.read_body(conn)

      raw_body when is_binary(raw_body) ->
        {:ok, raw_body, conn}
    end
  end

  defp handle_github_webhook(conn, raw_body) do
    secret = Application.get_env(:foreman_server, :github_webhook_secret, "")
    signature = List.first(get_req_header(conn, "x-hub-signature-256")) || ""
    event = List.first(get_req_header(conn, "x-github-event")) || ""
    delivery_id = List.first(get_req_header(conn, "x-github-delivery")) || ""

    # Verify HMAC-SHA256 signature when secret is configured.
    # If no secret is configured, skip verification (development mode).
    # When secret is configured, signature header must be present and valid.
    case verify_signature(secret, signature, raw_body, conn) do
      {:error, conn} -> conn
      {:ok, conn} ->
        case verify_event_type(event, conn) do
          {:error, conn} -> conn
          {:ok, conn} ->
            # Parse JSON payload.
            case Jason.decode(raw_body) do
              {:ok, payload} ->
                # Only set delivery_id from header when present; preserve body delivery_id otherwise.
                # This handles webhook dispatchers that send delivery_id in the body instead of the header.
                payload_with_delivery =
                  if delivery_id != "" do
                    Map.put(payload, "delivery_id", delivery_id)
                  else
                    payload
                  end

                case ForemanServer.PrMonitor.GhWebhookHandler.handle(payload_with_delivery) do
                  {:ok, %{commands_issued: count}} ->
                    send_json(conn, 200, %{ok: true, handled: true, commands_issued: count})

                  {:error, :duplicate} ->
                    # Idempotent — webhook was already processed.
                    send_json(conn, 200, %{ok: true, handled: false, reason: "duplicate delivery"})

                  {:error, :no_matching_run} ->
                    # PR doesn't match any known run — that's fine, just acknowledge.
                    send_json(conn, 200, %{ok: true, handled: false, reason: "no matching run"})

                  {:error, reason} ->
                    send_error(conn, 500, "INTERNAL", "webhook processing failed: #{inspect(reason)}", true)
                end

              {:error, %Jason.DecodeError{}} ->
                send_error(conn, 400, "BAD_REQUEST", "invalid JSON payload", false)
            end
        end
    end
  end

  # Returns {:ok, conn} when no secret is configured or verification passes.
  # Returns {:error, conn} with response already sent when verification fails.
  defp verify_signature(secret, _signature, _raw_body, conn) when secret == "" or is_nil(secret) do
    {:ok, conn}
  end

  defp verify_signature(_secret, signature, _raw_body, conn) when signature == "" do
    {:error, send_error(conn, 401, "UNAUTHORIZED", "missing webhook signature header", false)}
  end

  defp verify_signature(secret, signature, raw_body, conn) do
    if ForemanServer.PrMonitor.GhWebhookHandler.verify_signature(raw_body, signature, secret) do
      {:ok, conn}
    else
      {:error, send_error(conn, 401, "UNAUTHORIZED", "invalid webhook signature", false)}
    end
  end

  defp verify_event_type("pull_request", conn), do: {:ok, conn}
  defp verify_event_type(_event, conn) do
    {:error, send_json(conn, 200, %{ok: true, handled: false, reason: "event type not supported"})}
  end

  defp query_limit(nil, fallback), do: fallback
  defp query_limit("", fallback), do: fallback

  defp query_limit(value, fallback) do
    case Integer.parse(value) do
      {limit, ""} when limit > 0 -> limit
      _ -> fallback
    end
  end

  defp add_worktree_metadata(run, snapshot) do
    run_id = Map.get(run, :run_id)
    worktree = get_in(snapshot, [:worktrees, run_id]) || %{}
    # Normalize blank strings so || chain falls through to the next value.
    # put_present/3 also drops blanks, but being explicit here makes the intent
    # clear and guards against future changes.
    present? = fn v -> v != nil and v != "" end
    # Fall back to run's own fields when worktree snapshot is empty (native runs
    # use WorktreeManager.createWorktree which does not emit WorktreeCreated).
    worktree_path = cond do
      present?.(worktree[:worktree_path]) -> worktree[:worktree_path]
      present?.(worktree[:worktree]) -> worktree[:worktree]
      present?.(run[:worktree_path]) -> run[:worktree_path]
      present?.(run[:worktree]) -> run[:worktree]
      true -> nil
    end
    branch = cond do
      present?.(worktree[:branch]) -> worktree[:branch]
      present?.(worktree[:branch_name]) -> worktree[:branch_name]
      present?.(run[:branch]) -> run[:branch]
      present?.(run[:branch_name]) -> run[:branch_name]
      true -> nil
    end
    base = cond do
      present?.(worktree[:base_ref]) -> worktree[:base_ref]
      present?.(worktree[:base_branch]) -> worktree[:base_branch]
      present?.(run[:base_ref]) -> run[:base_ref]
      present?.(run[:base_branch]) -> run[:base_branch]
      true -> nil
    end
    revision = worktree[:revision]

    run
    |> put_present(:worktree_path, worktree_path)
    |> put_present(:worktree, worktree_path)
    |> put_present(:branch, branch)
    |> put_present(:branch_name, branch)
    |> put_present(:base_ref, base)
    |> put_present(:base_branch, base)
    |> put_present(:revision, revision)
  end

  defp add_run_metadata(run, snapshot, event_summaries, pr_gates_by_run) do
    run_id = Map.get(run, :run_id)
    summary = Map.get(event_summaries, run_id, %{})
    pr_gate = Map.get(pr_gates_by_run, run_id, %{})

    run
    |> put_present(:messages_count, run_message_count(snapshot, run_id))
    |> put_present(:events_count, Map.get(summary, :events_count))
    |> put_present(:diff_added, Map.get(summary, :diff_added))
    |> put_present(:diff_removed, Map.get(summary, :diff_removed))
    |> put_present(:pr_checks, pr_check_summary(pr_gate))
    |> put_present(:pr_review_decision, Map.get(pr_gate, :review))
    |> put_present(:review_decision, Map.get(pr_gate, :review))
    |> put_present(:pr_mergeable, Map.get(pr_gate, :mergeable))
    |> put_present(:mergeable, Map.get(pr_gate, :mergeable))
    |> add_run_metrics()
  end

  defp add_run_metrics(run) do
    total_cost_usd = Map.get(run, :costUsd, 0) || 0
    total_turns = Map.get(run, :turns, 0) || 0
    total_duration_ms = Map.get(run, :totalDurationMs)

    cost_per_turn =
      if total_turns > 0, do: total_cost_usd / total_turns, else: nil

    time_per_turn =
      if total_turns > 0 and total_duration_ms, do: total_duration_ms / total_turns, else: nil

    run
    |> put_present(:totalCostUsd, total_cost_usd)
    |> put_present(:totalTurns, total_turns)
    |> put_present(:totalDurationMs, total_duration_ms)
    |> put_present(:costPerTurn, cost_per_turn)
    |> put_present(:timePerTurn, time_per_turn)
  end

  defp run_message_count(snapshot, run_id) do
    snapshot
    |> get_in([:inbox_by_run, run_id])
    |> case do
      messages when is_list(messages) -> length(messages)
      _ -> nil
    end
  end

  defp pr_gates_by_run(snapshot) do
    snapshot
    |> Map.get(:pr_gates, %{})
    |> Map.values()
    |> Enum.reduce(%{}, fn gate, acc ->
      case Map.get(gate, :run_id) do
        run_id when is_binary(run_id) and run_id != "" -> Map.put(acc, run_id, gate)
        _ -> acc
      end
    end)
  end

  defp pr_check_summary(%{} = pr_gate) do
    case Map.get(pr_gate, :checks) do
      checks when is_map(checks) ->
        %{
          passed: int_value(Map.get(checks, :passed) || Map.get(checks, "passed")),
          failed: int_value(Map.get(checks, :failed) || Map.get(checks, "failed")),
          pending: int_value(Map.get(checks, :pending) || Map.get(checks, "pending"))
        }

      "passed" ->
        %{passed: 1, failed: 0, pending: 0}

      "passing" ->
        %{passed: 1, failed: 0, pending: 0}

      "failed" ->
        %{passed: 0, failed: 1, pending: 0}

      "failing" ->
        %{passed: 0, failed: 1, pending: 0}

      "pending" ->
        %{passed: 0, failed: 0, pending: 1}

      _ ->
        nil
    end
  end

  defp pr_check_summary(_pr_gate), do: nil

  defp int_value(value) when is_integer(value), do: value

  defp int_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> 0
    end
  end

  defp int_value(_value), do: 0

  defp run_event_summaries do
    ForemanServer.EventStore.all()
    |> Enum.reduce(%{}, fn event, acc ->
      case event_run_id(event) do
        run_id when is_binary(run_id) and run_id != "" ->
          update_in(acc, [run_id], fn summary ->
            summary
            |> Kernel.||(%{events_count: 0, diff_added: 0, diff_removed: 0})
            |> Map.update!(:events_count, &(&1 + 1))
            |> add_diff_totals(event.payload)
          end)

        _ ->
          acc
      end
    end)
  end

  defp event_run_id(%ForemanServer.Event{payload: payload, correlation_id: correlation_id}) do
    Map.get(payload, :run_id) || correlation_id
  end

  defp add_diff_totals(summary, payload) do
    file_changes_from_payload(payload)
    |> Enum.reduce(summary, fn change, acc ->
      acc
      |> Map.update!(:diff_added, &(&1 + int_value(Map.get(change, :additions))))
      |> Map.update!(:diff_removed, &(&1 + int_value(Map.get(change, :deletions))))
    end)
  end

  defp file_changes_from_payload(payload) when is_map(payload) do
    [
      nested_payload(payload, [:output, :changed]),
      nested_payload(payload, [:output, :files_changed]),
      nested_payload(payload, [:output, :filesChanged]),
      nested_payload(payload, [:output, :files]),
      Map.get(payload, :changed),
      Map.get(payload, :files_changed),
      Map.get(payload, :filesChanged),
      Map.get(payload, :files)
    ]
    |> Enum.find_value(&normalize_file_changes/1)
    |> Kernel.||([])
  end

  defp file_changes_from_payload(_payload), do: []

  defp nested_payload(map, [key | rest]) when is_map(map) do
    nested_payload(Map.get(map, key), rest)
  end

  defp nested_payload(value, []), do: value
  defp nested_payload(_value, _path), do: nil

  defp normalize_file_changes(changes) when is_list(changes) do
    changes
    |> Enum.map(&normalize_file_change/1)
    |> Enum.reject(&is_nil/1)
    |> then(fn
      [] -> nil
      normalized -> normalized
    end)
  end

  defp normalize_file_changes(_changes), do: nil

  defp normalize_file_change(%{} = change) do
    path = Map.get(change, :path) || Map.get(change, "path")

    if is_binary(path) and path != "" do
      %{
        path: path,
        additions: Map.get(change, :additions) || Map.get(change, "additions"),
        deletions: Map.get(change, :deletions) || Map.get(change, "deletions")
      }
    end
  end

  defp normalize_file_change(_change), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp log_view_mode(nil), do: {:ok, :compact}
  defp log_view_mode(""), do: {:ok, :compact}
  defp log_view_mode("compact"), do: {:ok, :compact}
  defp log_view_mode("raw"), do: {:ok, :raw}
  defp log_view_mode(_view), do: {:error, {:missing_or_invalid, :view}}

  defp authorize(conn) do
    expected = ForemanServer.Security.auth_token()

    cond do
      ForemanServer.Security.remote_auth_required?() and
          not ForemanServer.Security.token_configured?() ->
        {:error, :unauthorized}

      is_nil(expected) or expected == "" ->
        :ok

      get_req_header(conn, "authorization") == ["Bearer #{expected}"] ->
        :ok

      true ->
        {:error, :unauthorized}
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

  defp message_timestamp_sort_value(message) when is_map(message) do
    message
    |> Map.get(:created_at, Map.get(message, "created_at"))
    |> event_timestamp_sort_value()
  end

  defp event_timestamp_sort_value(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)

  defp event_timestamp_sort_value(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:microsecond)
  end

  defp event_timestamp_sort_value(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.to_unix(datetime, :microsecond)

      {:error, _reason} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> event_timestamp_sort_value(naive)
          {:error, _reason} -> 0
        end
    end
  end

  defp event_timestamp_sort_value(_value), do: 0

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

  # Filter tasks by updated_at timestamp when since parameter is provided
  defp maybe_filter_tasks_since(tasks, nil), do: tasks
  defp maybe_filter_tasks_since(tasks, ""), do: tasks

  defp maybe_filter_tasks_since(tasks, since) do
    case DateTime.from_iso8601(since) do
      {:ok, since_dt, _} ->
        Enum.filter(tasks, fn task ->
          case Map.get(task, :updated_at) do
            nil ->
              false

            updated when is_binary(updated) ->
              case DateTime.from_iso8601(updated) do
                {:ok, updated_dt, _} -> DateTime.compare(updated_dt, since_dt) == :gt
                {:error, _} -> false
              end

            _ ->
              false
          end
        end)

      {:error, _} ->
        # Invalid ISO8601 string, return all tasks
        tasks
    end
  end
end
