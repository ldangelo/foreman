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
