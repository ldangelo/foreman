defmodule ForemanServer.WorkerProtocolTest do
  use ExUnit.Case
  import Plug.Conn
  import Plug.Test

  @opts ForemanServer.Http.Router.init([])

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-worker-protocol-test-#{System.unique_integer([:positive])}"
      )

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

    {:ok, fixture: fixture()}
  end

  test "worker phase start rejects invalid bearer token before side effects", %{fixture: fixture} do
    conn =
      :post
      |> conn("/worker/v1/phases/developer/start", Jason.encode!(fixture["start"]))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer wrong")
      |> ForemanServer.Http.Router.call(@opts)

    assert conn.status == 401
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "UNAUTHORIZED"
    assert ForemanServer.EventStore.all() == []
  end

  test "worker phase fixture emits heartbeat tool and phase-complete events in order", %{
    fixture: fixture
  } do
    assert post_json("/worker/v1/phases/developer/start", fixture["start"]).status == 202
    assert post_json("/worker/v1/heartbeat", fixture["heartbeat"]).status == 202

    for event <- fixture["events"] do
      assert post_json("/worker/v1/events", event).status == 202
    end

    event_types =
      ForemanServer.EventStore.stream("worker:run-worker-fixture:worker-1")
      |> Enum.map(& &1.event_type)

    assert event_types == [
             "WorkerStarted",
             "WorkerHeartbeat",
             "ToolCallFinished",
             "PhaseCompleted"
           ]

    snapshot = ForemanServer.ProjectionStore.snapshot()
    assert snapshot.worker_heartbeats["run-worker-fixture:worker-1"].session_id == "session-1"

    assert snapshot.runs["run-worker-fixture"].tool_events |> hd() |> Map.get(:tool_name) ==
             "edit"

    assert snapshot.runs["run-worker-fixture"].phase_status["developer"] == "completed"
    assert snapshot.runs["run-worker-fixture"].artifact_paths == ["docs/reports/worker.md"]
  end

  test "worker terminal events authoritatively update run and task projections", %{
    fixture: fixture
  } do
    assert post_json("/worker/v1/phases/developer/start", fixture["start"]).status == 202

    run_failed = %{
      "run_id" => "run-worker-fixture",
      "project_id" => "proj-1",
      "phase_id" => "developer",
      "worker_id" => "worker-1",
      "type" => "run_failed",
      "sequence" => 1,
      "status" => "failed",
      "message" => "max turns",
      "details" => %{
        "task_id" => "task-1",
        "phase_id" => "developer",
        "failure_reason" => "max_turns"
      }
    }

    task_failed = %{
      "run_id" => "run-worker-fixture",
      "project_id" => "proj-1",
      "phase_id" => "developer",
      "worker_id" => "worker-1",
      "type" => "task_updated",
      "sequence" => 2,
      "status" => "failed",
      "details" => %{"task_id" => "task-1", "status" => "failed", "failure_reason" => "max_turns"}
    }

    assert post_json("/worker/v1/events", run_failed).status == 202
    assert post_json("/worker/v1/events", task_failed).status == 202

    event_types =
      ForemanServer.EventStore.stream("worker:run-worker-fixture:worker-1")
      |> Enum.map(& &1.event_type)

    assert event_types == ["WorkerStarted", "RunFailed", "TaskUpdated"]

    snapshot = ForemanServer.ProjectionStore.snapshot()
    assert snapshot.runs["run-worker-fixture"].status == "failed"
    assert snapshot.tasks["task-1"].status == "failed"
  end

  test "unprojected worker event advances sequence for following terminal events", %{
    fixture: fixture
  } do
    assert post_json("/worker/v1/phases/developer/start", fixture["start"]).status == 202

    report = %{
      "run_id" => "run-worker-fixture",
      "project_id" => "proj-1",
      "phase_id" => "developer",
      "worker_id" => "worker-1",
      "type" => "phase_report_produced",
      "sequence" => 1,
      "details" => %{"task_id" => "task-1", "phase_id" => "developer", "outcome" => "completed"}
    }

    completed = %{
      "run_id" => "run-worker-fixture",
      "project_id" => "proj-1",
      "phase_id" => "developer",
      "worker_id" => "worker-1",
      "type" => "phase_completed",
      "sequence" => 2,
      "status" => "completed",
      "details" => %{"task_id" => "task-1", "phase_id" => "developer"}
    }

    assert post_json("/worker/v1/events", report).status == 202
    assert post_json("/worker/v1/events", completed).status == 202

    snapshot = ForemanServer.ProjectionStore.snapshot()
    assert snapshot.worker_sequences["run-worker-fixture:worker-1"] == 2
    assert snapshot.runs["run-worker-fixture"].phase_status["developer"] == "completed"
  end

  test "out-of-order worker sequence is rejected before projection mutation", %{fixture: fixture} do
    assert post_json("/worker/v1/phases/developer/start", fixture["start"]).status == 202

    bad_event = fixture["events"] |> hd() |> Map.put("sequence", 3)
    conn = post_json("/worker/v1/events", bad_event)

    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["code"] == "CONFLICT"
    assert body["error"]["details"] == %{"actual" => 3, "expected" => 1}
    snapshot = ForemanServer.ProjectionStore.snapshot()
    assert snapshot.worker_sequences["run-worker-fixture:worker-1"] == 0
    refute Map.has_key?(snapshot.runs["run-worker-fixture"], :tool_events)
  end

  defp post_json(path, payload) do
    :post
    |> conn(path, Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer secret")
    |> ForemanServer.Http.Router.call(@opts)
  end

  defp fixture do
    "test/fixtures/worker-phase-success.json"
    |> File.read!()
    |> Jason.decode!()
  end
end
