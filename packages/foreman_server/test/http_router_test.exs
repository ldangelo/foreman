defmodule ForemanServer.Http.RouterTest do
  use ExUnit.Case
  import Plug.Conn
  import Plug.Test

  alias ForemanServer.ProjectionStore

  @opts ForemanServer.Http.Router.init([])

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-http-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :auth_token, "secret")
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :auth_token)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "rejects missing and invalid bearer token before side effects" do
    missing_conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(valid_command()))
      |> put_req_header("content-type", "application/json")
      |> ForemanServer.Http.Router.call(@opts)

    assert missing_conn.status == 401
    assert Jason.decode!(missing_conn.resp_body)["error"]["code"] == "UNAUTHORIZED"
    assert ForemanServer.EventStore.all() == []

    invalid_conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(valid_command()))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer wrong")
      |> ForemanServer.Http.Router.call(@opts)

    assert invalid_conn.status == 401
    assert Jason.decode!(invalid_conn.resp_body)["error"]["code"] == "UNAUTHORIZED"
    assert ForemanServer.EventStore.all() == []
  end

  test "accepts authorized JSON command and returns event/projection envelope" do
    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(valid_command()))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert [_event_id] = body["events"]
    assert body["projection_version"] == 1
    assert body["correlation_id"] == "corr-http"
  end

  test "authorized run.fail command appends RunFailed projection event" do
    append_run_event("RunStarted", %{
      run_id: "run-http-fail",
      task_id: "task-http-fail",
      project_id: "proj-http",
      phase_order: ["developer"],
      current_phase: "developer"
    })

    command = %{
      "command_id" => "cmd-run-fail",
      "command_type" => "run.fail",
      "schema_version" => 1,
      "payload" => %{
        "run_id" => "run-http-fail",
        "task_id" => "task-http-fail",
        "project_id" => "proj-http",
        "failure_reason" => "reset"
      },
      "metadata" => %{"correlation_id" => "run-http-fail"}
    }

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(command))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202
    assert ProjectionStore.snapshot().runs["run-http-fail"].status == "failed"
  end

  test "authorized run.reset command marks run terminal reset" do
    append_run_event("RunStarted", %{
      run_id: "run-http-reset",
      task_id: "task-http-reset",
      project_id: "proj-http",
      phase_order: ["developer"],
      current_phase: "developer"
    })

    command = %{
      "command_id" => "cmd-run-reset",
      "command_type" => "run.reset",
      "schema_version" => 1,
      "payload" => %{
        "run_id" => "run-http-reset",
        "project_id" => "proj-http",
        "reason" => "foreman retry"
      },
      "metadata" => %{"correlation_id" => "run-http-reset"}
    }

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(command))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    projection = ProjectionStore.snapshot()
    assert conn.status == 202
    assert projection.runs["run-http-reset"].status == "reset"
    assert projection.runs["run-http-reset"].current_phase == nil
    assert projection.status_counts.active == 0
  end

  test "authorized phase commands append lifecycle projection events" do
    append_run_event("RunStarted", %{
      run_id: "run-http-phase",
      task_id: "task-http-phase",
      project_id: "proj-http",
      phase_order: ["developer", "qa"],
      current_phase: "developer"
    })

    command = %{
      "command_id" => "cmd-phase-complete",
      "command_type" => "phase.complete",
      "schema_version" => 1,
      "payload" => %{
        "run_id" => "run-http-phase",
        "task_id" => "task-http-phase",
        "project_id" => "proj-http",
        "phase_id" => "developer"
      },
      "metadata" => %{"correlation_id" => "run-http-phase"}
    }

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(command))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202
    assert ProjectionStore.snapshot().runs["run-http-phase"].phase_status["developer"] == "completed"
  end

  test "run log/report/debug endpoints require bearer token" do
    seed_debug_http_run()

    for path <- [
          "/api/v1/runs/run-http-debug/logs",
          "/api/v1/runs/run-http-debug/report",
          "/api/v1/runs/run-http-debug/debug"
        ] do
      conn =
        :get
        |> conn(path)
        |> ForemanServer.Http.Router.call(@opts)

      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "UNAUTHORIZED"
    end
  end

  test "authorized run log endpoint returns compact and raw views and rejects invalid view" do
    seed_debug_http_run()

    compact_conn =
      :get
      |> conn("/api/v1/runs/run-http-debug/logs")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert compact_conn.status == 200
    compact = Jason.decode!(compact_conn.resp_body)
    assert compact["ok"] == true
    assert compact["logs"]["mode"] == "compact"
    assert Enum.any?(compact["logs"]["entries"], &(&1["message"] == "http stdout"))

    raw_conn =
      :get
      |> conn("/api/v1/runs/run-http-debug/logs?view=raw")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert raw_conn.status == 200
    raw = Jason.decode!(raw_conn.resp_body)
    assert raw["logs"]["mode"] == "raw"
    assert Enum.any?(raw["logs"]["entries"], &(&1["payload"]["output"] == "http stdout"))

    invalid_conn =
      :get
      |> conn("/api/v1/runs/run-http-debug/logs?view=verbose")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert invalid_conn.status == 400
    assert Jason.decode!(invalid_conn.resp_body)["error"]["message"] == "missing or invalid view"
  end

  test "authorized raw log endpoint JSON-encodes long unicode logs and redacts colon secrets" do
    append_run_event("RunStarted", %{run_id: "run-http-unicode", phase_order: ["developer"]})

    append_worker_event("WorkerStdout", %{
      run_id: "run-http-unicode",
      phase_id: "developer",
      worker_id: "worker-http-unicode",
      output:
        "api-key=http-hyphen access-token=http-hyphen-access auth-token: http-hyphen-auth client-secret=http-hyphen-client " <>
          String.duplicate("🔐", 2_000) <>
          " token: http-token access_token=http-access auth_token: http-auth client_secret=http-client password: hunter2 Authorization: Bearer bearer-token {\"token\":\"http-json-token\"} {\"client_secret\": \"http-json-client\"}",
      sequence: 1
    })

    raw_conn =
      :get
      |> conn("/api/v1/runs/run-http-unicode/logs?view=raw")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert raw_conn.status == 200
    raw = Jason.decode!(raw_conn.resp_body)
    [entry] = raw["logs"]["entries"]
    output = entry["payload"]["output"]

    assert String.valid?(output)
    assert String.ends_with?(output, "...[truncated]")

    for secret <- [
          "http-hyphen",
          "http-hyphen-access",
          "http-hyphen-auth",
          "http-hyphen-client",
          "http-token",
          "http-access",
          "http-auth",
          "http-client",
          "hunter2",
          "bearer-token",
          "http-json-token",
          "http-json-client"
        ] do
      refute raw_conn.resp_body =~ secret
    end
  end

  test "doctor and metrics endpoints require valid bearer token" do
    for path <- ["/api/v1/doctor", "/api/v1/metrics"] do
      missing_conn =
        :get
        |> conn(path)
        |> ForemanServer.Http.Router.call(@opts)

      assert missing_conn.status == 401
      assert Jason.decode!(missing_conn.resp_body)["error"]["code"] == "UNAUTHORIZED"

      invalid_conn =
        :get
        |> conn(path)
        |> put_req_header("authorization", "Bearer wrong")
        |> ForemanServer.Http.Router.call(@opts)

      assert invalid_conn.status == 401
      assert Jason.decode!(invalid_conn.resp_body)["error"]["code"] == "UNAUTHORIZED"
    end
  end

  test "authorized doctor and metrics endpoints expose operational status" do
    seed_debug_http_run()

    doctor_conn =
      :get
      |> conn("/api/v1/doctor")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert doctor_conn.status == 200
    doctor = Jason.decode!(doctor_conn.resp_body)["doctor"]
    assert doctor["ok"] == true
    assert doctor["checks"]["db"]["ok"] == true
    assert doctor["checks"]["projections"]["projection_lag"] == 0
    assert doctor["checks"]["workers"]["ok"] == true
    assert doctor["checks"]["vcs"]["ok"] == true
    assert doctor["checks"]["provider_adapters"]["ok"] == true
    assert doctor["checks"]["integrations"]["ok"] == true

    metrics_conn =
      :get
      |> conn("/api/v1/metrics")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert metrics_conn.status == 200
    metrics = Jason.decode!(metrics_conn.resp_body)["metrics"]
    assert metrics["gauges"]["projection_lag"] == 0
  end

  test "authorized run report and debug endpoints return event-backed summaries" do
    seed_debug_http_run()

    report_conn =
      :get
      |> conn("/api/v1/runs/run-http-debug/report")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert report_conn.status == 200
    report = Jason.decode!(report_conn.resp_body)["report"]
    assert report["summary"]["event_count"] == 2
    assert report["artifact_paths"] == ["http-artifact.md"]

    debug_conn =
      :get
      |> conn("/api/v1/runs/run-http-debug/debug")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert debug_conn.status == 200
    debug = Jason.decode!(debug_conn.resp_body)["debug"]
    assert debug["summary"]["event_count"] == 2
    assert Enum.map(debug["timeline"], & &1["type"]) == ["RunStarted", "WorkerStdout"]
  end

  test "authorized top-level external trigger command creates and dedupes integration task" do
    command = top_level_external_trigger_command()

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(command))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert [_event_id] = body["events"]

    task_id =
      ProjectionStore.snapshot().integration_dedupe["github:fortium/foreman:evt-http-top"].task_id

    assert ProjectionStore.snapshot().tasks[task_id].external_link ==
             "https://github.com/fortium/foreman/issues/22"

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(command))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202

    assert ProjectionStore.snapshot().integration_dedupe["github:fortium/foreman:evt-http-top"].task_id ==
             task_id
  end

  test "authorized external trigger command creates and dedupes integration task" do
    command = external_trigger_command("cmd-ext-http-1")

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(command))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert [_event_id] = body["events"]

    task_id =
      ProjectionStore.snapshot().integration_dedupe["github:fortium/foreman:evt-http"].task_id

    assert ProjectionStore.snapshot().tasks[task_id].external_link ==
             "https://github.com/fortium/foreman/issues/20"

    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(external_trigger_command("cmd-ext-http-2")))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 202

    assert ProjectionStore.snapshot().integration_dedupe["github:fortium/foreman:evt-http"].task_id ==
             task_id
  end

  test "external trigger command validates input through HTTP boundary" do
    conn =
      :post
      |> conn(
        "/api/v1/commands",
        Jason.encode!(%{
          "command_id" => "cmd-ext-bad",
          "command_type" => "ExternalTriggerCommand",
          "payload" => %{
            "source" => "github",
            "repo" => "fortium/foreman",
            "event_id" => "evt-bad",
            "external_id" => "21",
            "project_id" => "foreman",
            "event_type" => "opened"
          }
        })
      )
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["message"] == "missing or invalid external_link"
  end

  test "invalid JSON command returns validation error" do
    conn =
      :post
      |> conn("/api/v1/commands", Jason.encode!(%{"command_id" => "cmd-bad"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == false
    assert body["error"]["code"] == "VALIDATION_FAILED"
  end

  defp seed_debug_http_run do
    append_run_event("RunStarted", %{run_id: "run-http-debug", phase_order: ["developer"]})

    append_worker_event("WorkerStdout", %{
      run_id: "run-http-debug",
      phase_id: "developer",
      worker_id: "worker-http-debug",
      output: "http stdout",
      artifact_paths: ["http-artifact.md"],
      sequence: 1
    })
  end

  defp append_run_event(event_type, payload) do
    ForemanServer.EventStore.append(%{
      stream_id: "run:#{payload.run_id}",
      event_type: event_type,
      payload: payload,
      metadata: %{
        correlation_id: payload.run_id,
        idempotency_key: "#{event_type}:#{System.unique_integer([:positive])}"
      }
    })
  end

  defp append_worker_event(event_type, payload) do
    ForemanServer.EventStore.append(%{
      stream_id: "worker:#{payload.run_id}:#{payload.worker_id}",
      event_type: event_type,
      payload: payload,
      metadata: %{
        correlation_id: payload.run_id,
        idempotency_key: "#{event_type}:#{System.unique_integer([:positive])}"
      }
    })
  end

  defp valid_command do
    %{
      "command_id" => "cmd-http",
      "command_type" => "task.create",
      "schema_version" => 1,
      "payload" => %{"task_id" => "task-http"},
      "metadata" => %{"correlation_id" => "corr-http", "idempotency_key" => "cmd-http"}
    }
  end

  defp top_level_external_trigger_command do
    %{
      "command_type" => "ExternalTriggerCommand",
      "source" => "github",
      "repo" => "fortium/foreman",
      "event_id" => "evt-http-top",
      "external_id" => "22",
      "project_id" => "foreman",
      "event_type" => "opened",
      "url" => "https://github.com/fortium/foreman/issues/22"
    }
  end

  defp external_trigger_command(command_id) do
    %{
      "command_id" => command_id,
      "command_type" => "ExternalTriggerCommand",
      "payload" => %{
        "source" => "github",
        "repo" => "fortium/foreman",
        "event_id" => "evt-http",
        "external_id" => "20",
        "project_id" => "foreman",
        "event_type" => "opened",
        "url" => "https://github.com/fortium/foreman/issues/20"
      },
      "metadata" => %{"correlation_id" => "corr-ext-http"}
    }
  end
end
