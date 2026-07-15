defmodule ForemanServer.Http.RouterTest do
  use ExUnit.Case
  import Plug.Conn
  import Plug.Test

  alias ForemanServer.{Inbox, ProjectionStore}

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

  test "run log/report/debug endpoints require bearer token" do
    task_debug_http_run()

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
    task_debug_http_run()

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
    task_debug_http_run()

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

  test "authorized runs endpoint includes projected worktree metadata" do
    append_event("TaskCreated", "task:task-run-worktree-http", %{
      task_id: "task-run-worktree-http",
      project_id: "proj-run-worktree-http",
      title: "Run Worktree HTTP",
      status: "ready"
    })

    append_run_event("RunStarted", %{
      run_id: "run-worktree-http",
      task_id: "task-run-worktree-http",
      phase_order: ["developer"],
      status: "running"
    })

    append_event("WorktreeCreated", "vcs:op-run-worktree-http", %{
      run_id: "run-worktree-http",
      operation_id: "op-run-worktree-http",
      worktree_path: "/tmp/foreman/run-worktree-http",
      branch: "foreman/run-worktree-http",
      base_ref: "main",
      revision: "abc123"
    })

    assert {:ok, _} =
             Inbox.send_operator_message(%{
               message_id: "msg-run-worktree-http",
               run_id: "run-worktree-http",
               from: "developer",
               to: "qa",
               subject: "inspect diff",
               body: ~s({"message":"please inspect"})
             })

    append_run_event("ToolCallFinished", %{
      run_id: "run-worktree-http",
      output: %{
        changed: [
          %{path: "lib/a.ex", additions: 3, deletions: 1},
          %{path: "test/a_test.exs", additions: 5, deletions: 0}
        ]
      }
    })

    append_event("PrGateObserved", "pr:run-worktree-http", %{
      pr_id: "pr-run-worktree-http",
      run_id: "run-worktree-http",
      checks: %{passed: 2, failed: 1, pending: 3},
      review: "changes_requested",
      mergeable: false
    })

    conn =
      :get
      |> conn("/api/v1/runs?project_id=proj-run-worktree-http")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert run = Enum.find(body["runs"], &(&1["run_id"] == "run-worktree-http"))
    assert run["project_id"] == "proj-run-worktree-http"
    assert run["worktree"] == "/tmp/foreman/run-worktree-http"
    assert run["worktree_path"] == "/tmp/foreman/run-worktree-http"
    assert run["branch"] == "foreman/run-worktree-http"
    assert run["branch_name"] == "foreman/run-worktree-http"
    assert run["base_ref"] == "main"
    assert run["base_branch"] == "main"
    assert run["revision"] == "abc123"
    assert run["messages_count"] == 1
    assert run["events_count"] == 5
    assert run["diff_added"] == 8
    assert run["diff_removed"] == 1
    assert run["pr_checks"] == %{"passed" => 2, "failed" => 1, "pending" => 3}
    assert run["pr_review_decision"] == "changes_requested"
    assert run["review_decision"] == "changes_requested"
    assert run["pr_mergeable"] == false
    assert run["mergeable"] == false
  end

  test "authorized run report and debug endpoints return event-backed summaries" do
    task_debug_http_run()

    report_conn =
      :get
      |> conn("/api/v1/runs/run-http-debug/report")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert report_conn.status == 200
    report = Jason.decode!(report_conn.resp_body)["report"]
    assert report["summary"]["event_count"] == 3
    assert report["artifact_paths"] == ["http-artifact.md"]

    debug_conn =
      :get
      |> conn("/api/v1/runs/run-http-debug/debug")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert debug_conn.status == 200
    debug = Jason.decode!(debug_conn.resp_body)["debug"]
    assert debug["summary"]["event_count"] == 3

    assert Enum.map(debug["timeline"], & &1["type"]) == [
             "RunStarted",
             "WorkerStdout",
             "ToolCallFinished"
           ]

    stdout = Enum.find(debug["timeline"], &(&1["type"] == "ToolCallFinished"))
    assert get_in(stdout, ["payload", "output", "text"]) == "file diff"

    assert stdout["file_changes"] == [
             %{
               "path" => "lib/debug.ex",
               "change" => "M",
               "additions" => 2,
               "deletions" => 1,
               "conflict" => false
             }
           ]
  end

  test "authorized debug endpoint includes PR lifecycle payloads for fallback parsing" do
    append_run_event("RunStarted", %{run_id: "run-http-pr-debug", phase_order: ["developer"]})

    append_run_event("PrReady", %{
      run_id: "run-http-pr-debug",
      project_id: "proj-http-pr-debug",
      task_id: "task-http-pr-debug",
      pr_url: "https://github.com/acme/repo/pull/44",
      head_sha: "abc999",
      base_branch: "main",
      branch_name: "foreman/task-http-pr-debug"
    })

    append_event("PrGateObserved", "pr:run-http-pr-debug", %{
      pr_id: "pr-run-http-pr-debug",
      run_id: "run-http-pr-debug",
      checks: %{passed: 1, failed: 0, pending: 2},
      review: "approved",
      mergeable: "mergeable"
    })

    conn =
      :get
      |> conn("/api/v1/runs/run-http-pr-debug/debug")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 200
    timeline = Jason.decode!(conn.resp_body)["debug"]["timeline"]
    assert Enum.map(timeline, & &1["type"]) == ["RunStarted", "PrReady", "PrGateObserved"]
    pr_ready = Enum.find(timeline, &(&1["type"] == "PrReady"))
    pr_gate = Enum.find(timeline, &(&1["type"] == "PrGateObserved"))

    assert get_in(pr_ready, ["payload", "pr_url"]) == "https://github.com/acme/repo/pull/44"
    assert get_in(pr_ready, ["payload", "head_sha"]) == "abc999"
    assert get_in(pr_gate, ["payload", "checks", "pending"]) == 2
    assert get_in(pr_gate, ["payload", "review"]) == "approved"
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

  test "inbox endpoint returns event-projected message contents by project" do
    append_event("ProjectRegistered", "project:proj-inbox-http", %{
      project_id: "proj-inbox-http",
      path: "/tmp/proj-inbox-http"
    })

    append_event("TaskCreated", "task:task-inbox-http", %{
      task_id: "task-inbox-http",
      project_id: "proj-inbox-http",
      title: "Inbox HTTP"
    })

    append_event("RunStarted", "run:run-inbox-http", %{
      run_id: "run-inbox-http",
      task_id: "task-inbox-http",
      phase_order: ["developer"]
    })

    assert {:ok, _} =
             Inbox.send_operator_message(%{
               message_id: "msg-inbox-http",
               run_id: "run-inbox-http",
               from: "developer",
               to: "qa",
               subject: "review-needed",
               body: ~s({"message":"please inspect"})
             })

    conn =
      :get
      |> conn("/api/v1/inbox?project_id=proj-inbox-http&run_id=run-inbox-http")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 200
    assert %{"ok" => true, "inbox" => [message]} = Jason.decode!(conn.resp_body)
    assert message["message_id"] == "msg-inbox-http"
    assert message["project_id"] == "proj-inbox-http"
    assert message["sender_agent_type"] == "developer"
    assert message["recipient_agent_type"] == "qa"
    assert message["subject"] == "review-needed"
    assert message["body"] == ~s({"message":"please inspect"})
  end

  test "inbox endpoint sorts messages by timestamp oldest first" do
    append_event("ProjectRegistered", "project:proj-inbox-sort", %{
      project_id: "proj-inbox-sort",
      path: "/tmp/proj-inbox-sort"
    })

    append_event("TaskCreated", "task:task-inbox-sort", %{
      task_id: "task-inbox-sort",
      project_id: "proj-inbox-sort",
      title: "Inbox Sort"
    })

    append_event("RunStarted", "run:run-inbox-sort", %{
      run_id: "run-inbox-sort",
      task_id: "task-inbox-sort",
      phase_order: ["developer"]
    })

    append_event("InboxMessageAppended", "inbox:run-inbox-sort", %{
      message_id: "msg-old",
      run_id: "run-inbox-sort",
      sender_agent_type: "developer",
      recipient_agent_type: "qa",
      subject: "old",
      body: "old",
      created_at: ~U[2026-01-01 00:00:00Z]
    })

    append_event("InboxMessageAppended", "inbox:run-inbox-sort", %{
      message_id: "msg-new",
      run_id: "run-inbox-sort",
      sender_agent_type: "developer",
      recipient_agent_type: "qa",
      subject: "new",
      body: "new",
      created_at: ~U[2026-01-01 00:01:00Z]
    })

    conn =
      :get
      |> conn("/api/v1/inbox?project_id=proj-inbox-sort&run_id=run-inbox-sort")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 200
    assert %{"ok" => true, "inbox" => messages} = Jason.decode!(conn.resp_body)
    assert Enum.map(messages, & &1["message_id"]) == ["msg-old", "msg-new"]
  end

  test "events endpoint sorts naive timestamps from postgres-compatible rows" do
    append_event("ProjectRegistered", "project:proj-events-http", %{
      project_id: "proj-events-http",
      path: "/tmp/proj-events-http"
    })

    append_event("TaskCreated", "task:task-events-http", %{
      task_id: "task-events-http",
      project_id: "proj-events-http",
      title: "Events HTTP"
    })

    assert {:ok, _} =
             ForemanServer.EventStore.append(%{
               stream_id: "run:run-events-http",
               event_type: "RunStarted",
               payload: %{
                 run_id: "run-events-http",
                 task_id: "task-events-http",
                 phase_order: ["developer"]
               },
               occurred_at: ~N[2026-01-01 00:00:00],
               metadata: %{
                 correlation_id: "run-events-http",
                 idempotency_key: "run-events-http-started"
               }
             })

    assert {:ok, _} =
             ForemanServer.EventStore.append(%{
               stream_id: "worker:run-events-http:worker-events-http",
               event_type: "WorkerStdout",
               payload: %{
                 run_id: "run-events-http",
                 task_id: "task-events-http",
                 phase_id: "developer",
                 worker_id: "worker-events-http",
                 output: "events stdout",
                 sequence: 1
               },
               occurred_at: ~N[2026-01-01 00:01:00],
               metadata: %{
                 correlation_id: "run-events-http",
                 idempotency_key: "run-events-http-stdout"
               }
             })

    conn =
      :get
      |> conn("/api/v1/events?run_id=run-events-http&limit=5")
      |> put_req_header("authorization", "Bearer secret")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["ok"] == true
    assert Enum.map(body["events"], & &1["event_type"]) == ["WorkerStdout", "RunStarted"]
    assert Enum.all?(body["events"], &(&1["project_id"] == "proj-events-http"))
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

  defp task_debug_http_run do
    append_run_event("RunStarted", %{run_id: "run-http-debug", phase_order: ["developer"]})

    append_worker_event("WorkerStdout", %{
      run_id: "run-http-debug",
      phase_id: "developer",
      worker_id: "worker-http-debug",
      output: "http stdout",
      artifact_paths: ["http-artifact.md"],
      sequence: 1
    })

    append_run_event("ToolCallFinished", %{
      run_id: "run-http-debug",
      output: %{
        text: "file diff",
        changed: [%{path: "lib/debug.ex", additions: 2, deletions: 1}]
      }
    })
  end

  defp append_run_event(event_type, payload) do
    append_event(event_type, "run:#{payload.run_id}", payload)
  end

  defp append_event(event_type, stream_id, payload) do
    ForemanServer.EventStore.append(%{
      stream_id: stream_id,
      event_type: event_type,
      payload: payload,
      metadata: %{
        correlation_id: Map.get(payload, :run_id) || Map.get(payload, :task_id) || stream_id,
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
