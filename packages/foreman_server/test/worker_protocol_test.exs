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
             "ToolCallFinished"
           ]

    snapshot = ForemanServer.ProjectionStore.snapshot()
    assert snapshot.worker_heartbeats["run-worker-fixture:worker-1"].session_id == "session-1"

    assert snapshot.runs["run-worker-fixture"].tool_events |> hd() |> Map.get(:tool_name) ==
             "edit"

    assert snapshot.runs["run-worker-fixture"].phase_status["developer"] == "completed"
    assert snapshot.runs["run-worker-fixture"].artifact_paths == ["docs/reports/worker.md"]
  end
  test "WorkerStarted payload preserves session_id, prompt_path, tool_names, and artifact_paths through normalize_payload" do
    # Verify that known_worker_payload_keys normalization in CommandRouter does not
    # strip these fields from worker.record payloads.
    :ok = Application.put_env(:foreman_server, :auth_token, "secret")

    on_exit(fn -> Application.delete_env(:foreman_server, :auth_token) end)

    payload = %{
      "run_id" => "run-normalize-test",
      "worker_id" => "worker-normalize-1",
      "phase_id" => "tester",
      "adapter" => "pi_sdk",
      "session_id" => "session-normalize-1",
      "prompt_path" => ".foreman/prompts/test.md",
      "tool_names" => ["read", "edit", "bash"],
      "artifact_paths" => ["out.md"]
    }

    assert post_json("/worker/v1/phases/tester/start", payload).status == 202

    started_event =
      ForemanServer.EventStore.stream("worker:run-normalize-test:worker-normalize-1")
      |> Enum.find(&(&1.event_type == "WorkerStarted"))

    assert started_event, "WorkerStarted event must be persisted"

    p = started_event.payload

    # Core identity
    assert p.run_id == "run-normalize-test"
    assert p.worker_id == "worker-normalize-1"
    assert p.phase_id == "tester"

    # Metadata fields that old normalize_payload stripped — must survive
    assert p.session_id == "session-normalize-1"
    assert p.prompt_path == ".foreman/prompts/test.md"
    assert p.tool_names == ["read", "edit", "bash"]
    assert p.artifact_paths == ["out.md"]
    assert p.sequence == 0
  end

  test "worker terminal events authoritatively update run and task projections", %{
    fixture: fixture
  } do
    # Pre-seed run so run.fail can find it (run aggregate requires exists check).
    assert seed_run("run-worker-fixture") == :ok

    assert post_json("/worker/v1/phases/developer/start", fixture["start"]).status == 202

    # Pre-seed task so task.update can find it (task aggregate requires exists check).
    assert seed_task("task-1") == :ok

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

    assert event_types == ["WorkerStarted"]

    # Verify routed RunFailed carries task_id, failure_reason, and reason.
    run_failed_event =
      ForemanServer.EventStore.stream("run:run-worker-fixture")
      |> Enum.find(&(&1.event_type == "RunFailed"))

    assert run_failed_event
    assert run_failed_event.payload.task_id == "task-1"
    assert run_failed_event.payload.failure_reason == "max_turns"
    assert run_failed_event.payload.reason == "max_turns"

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

  test "non-terminal worker events are rejected after run terminal", %{fixture: fixture} do
    # Pre-seed run so run.fail can find it.
    assert seed_run("run-worker-fixture") == :ok

    assert post_json("/worker/v1/phases/developer/start", fixture["start"]).status == 202

    run_failed = %{
      "run_id" => "run-worker-fixture",
      "project_id" => "proj-1",
      "phase_id" => "developer",
      "worker_id" => "worker-1",
      "type" => "run_failed",
      "sequence" => 1,
      "status" => "failed",
      "details" => %{"task_id" => "task-1", "failure_reason" => "max_turns"}
    }

    assert post_json("/worker/v1/events", run_failed).status == 202

    assert {:error, {:run_not_active, "run-worker-fixture"}} =
             ForemanServer.WorkerProtocol.heartbeat(%{
               run_id: "run-worker-fixture",
               phase_id: "developer",
               worker_id: "worker-1",
               sequence: 2
             })

    event_types =
      ForemanServer.EventStore.stream("worker:run-worker-fixture:worker-1")
      |> Enum.map(& &1.event_type)

    assert event_types == ["WorkerStarted"]
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

  test "run_completed worker event routes to Run aggregate and preserves task_id, failure_reason, and reason" do
    project_id = "proj-seed:run-complete-test"
    assert seed_run("run-complete-test") == :ok

    # Confirm the run.start saga reserved a slot for this project before
    # the worker terminal event arrives.
    initial_slot_events =
      ForemanServer.EventStore.stream("project_run_limit:#{project_id}")
      |> Enum.map(& &1.event_type)

    assert "ProjectRunStarted" in initial_slot_events

    completed = %{
      "run_id" => "run-complete-test",
      "project_id" => "proj-1",
      "phase_id" => "developer",
      "worker_id" => "worker-complete-1",
      "type" => "run_completed",
      "sequence" => 1,
      "status" => "completed",
      "details" => %{
        "task_id" => "task-complete-1",
        "failure_reason" => "all_done"
      }
    }

    assert post_json("/worker/v1/events", completed).status == 202

    completed_event =
      ForemanServer.EventStore.stream("run:run-complete-test")
      |> Enum.find(&(&1.event_type == "RunCompleted"))

    assert completed_event
    assert completed_event.payload.task_id == "task-complete-1"
    assert completed_event.payload.failure_reason == "all_done"
    assert completed_event.payload.reason == "all_done"

    # Worker terminal payloads omit `project_id`; the saga must resolve it
    # from the canonical run projection and release the slot synchronously,
    # not wait on `ProjectRunLimitSweeper`.
    slot_events =
      ForemanServer.EventStore.stream("project_run_limit:#{project_id}")
      |> Enum.map(& &1.event_type)

    assert "ProjectRunCompleted" in slot_events

    {limit_state, _version} =
      ForemanServer.Aggregate.load(
        ForemanServer.Aggregates.ProjectRunLimit,
        "project_run_limit:#{project_id}"
      )

    assert limit_state.active_run_ids == MapSet.new()
  end
  test "WorkerProtocol.emit/2 with nil sequence auto-fills next sequence and stores typed struct" do
    # Seed the worker stream with WorkerStarted so the aggregate has a sequence baseline.
    started = %ForemanServer.Events.WorkerStarted{
      run_id: "emit-typed-test",
      worker_id: "w1",
      phase_id: "developer",
      adapter: "test",
      sequence: 0
    }
    assert {:ok, _} = ForemanServer.WorkerProtocol.emit("WorkerStarted", started)

    # Emit a typed WorkerHeartbeat with nil sequence — emit/2 must auto-fill via
    # next_sequence/1 from the Worker's current state in the event store.
    heartbeat = %ForemanServer.Events.WorkerHeartbeat{
      run_id: "emit-typed-test",
      worker_id: "w1",
      sequence: nil
    }
    assert {:ok, _} = ForemanServer.WorkerProtocol.emit("WorkerHeartbeat", heartbeat)

    # Read the persisted event back and verify.
    events = ForemanServer.EventStore.stream("worker:emit-typed-test:w1")
    assert length(events) == 2

    [%{event_type: "WorkerStarted", payload: started_payload},
     %{event_type: "WorkerHeartbeat", payload: hb_payload}] = events

    # Persisted payload must be a typed struct, not a plain map.
    assert is_struct(started_payload, ForemanServer.Events.WorkerStarted)
    assert is_struct(hb_payload, ForemanServer.Events.WorkerHeartbeat)
    assert hb_payload.run_id == "emit-typed-test"
    assert hb_payload.worker_id == "w1"

    # Sequence was auto-filled to 1 (next after WorkerStarted's 0).
    assert hb_payload.sequence == 1

    # :event_type is a command-layer key — must not be in the stored payload.
    refute Map.has_key?(hb_payload, :event_type)
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

  # Pre-seed a Run aggregate stream so terminal events can find it.
  defp seed_run(run_id) do
    {:ok, _} =
      ForemanServer.CommandRouter.handle(%{
        command_id: "test-seed:#{run_id}",
        command_type: "run.start",
        payload: %{run_id: run_id, project_id: "proj-seed:#{run_id}"}
      })

    :ok
  end

  # Pre-seed a Task aggregate stream so task.update can find it.
  defp seed_task(task_id) do
    {:ok, _} =
      ForemanServer.CommandRouter.handle(%{
        command_id: "test-seed:task:#{task_id}",
        command_type: "task.create",
        payload: %{task_id: task_id, project_id: "proj-1"}
      })

    :ok
  end
end
