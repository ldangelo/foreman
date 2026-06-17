defmodule ForemanServer.AttachBridgeTest do
  use ExUnit.Case
  import Plug.Conn
  import Plug.Test

  alias ForemanServer.{AttachBridge, EventStore, ProjectionStore, WorkerProtocol}

  @opts ForemanServer.Http.Router.init([])

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-attach-test-#{System.unique_integer([:positive])}")

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

  test "Pi SDK worker attach endpoint opens interactive attach mode" do
    seed_pi_worker("run-attach", "worker-1")

    conn = get_json("/api/v1/runs/run-attach/attach")
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert body["ok"] == true
    assert body["attach"]["status"] == "ready"
    assert body["attach"]["mode"] == "interactive"
    assert body["attach"]["session_id"] == "session-run-attach"
    assert body["attach"]["attach"]["session_path"] == "/tmp/run-attach.jsonl"

    snapshot = ProjectionStore.snapshot()
    assert snapshot.attach_requests["run-attach"].event_type == "AttachRequested"
  end

  test "unsupported provider records reason and alternative commands" do
    seed_worker_events(%{
      run_id: "run-unsupported",
      phase_id: "developer",
      worker_id: "worker-unsupported",
      adapter: "mock",
      session_id: "mock-session",
      attach: %{session_path: "/tmp/mock.jsonl"}
    })

    assert {:ok, %{result: result}} = AttachBridge.request_attach(%{run_id: "run-unsupported"})

    assert result.status == "unsupported"
    assert result.reason == "provider mock does not support attach"
    assert "foreman debug run-unsupported" in result.alternatives

    assert ProjectionStore.snapshot().attach_requests["run-unsupported"].event_type ==
             "AttachUnsupported"
  end

  test "operator interrupt and resume records next recovery action" do
    seed_pi_worker("run-interrupt", "worker-1")

    interrupt =
      post_json("/api/v1/runs/run-interrupt/interrupt", %{
        phase_id: "developer",
        worker_id: "worker-1",
        reason: "operator_pressed_ctrl_c"
      })

    assert interrupt.status == 202

    resume =
      post_json("/api/v1/runs/run-interrupt/resume", %{
        phase_id: "developer",
        worker_id: "worker-1",
        next_action: "restart_phase"
      })

    assert resume.status == 202

    snapshot = ProjectionStore.snapshot()
    assert snapshot.runs["run-interrupt"].phase_status["developer"] == "resume_requested"
    assert snapshot.runs["run-interrupt"].recovery_next_action == "restart_phase"

    assert Enum.map(snapshot.interactive_recovery["run-interrupt"], & &1.event_type) == [
             "HumanInterruptionRecorded",
             "InteractiveRecoveryResumed"
           ]
  end

  test "attach and recovery projections rebuild from durable events" do
    seed_pi_worker("run-rebuild", "worker-1")
    assert {:ok, _} = AttachBridge.request_attach(%{run_id: "run-rebuild"})

    assert {:ok, _} =
             AttachBridge.interrupt_phase(%{run_id: "run-rebuild", phase_id: "developer"})

    assert {:ok, _} =
             AttachBridge.resume_after_interrupt(%{
               run_id: "run-rebuild",
               phase_id: "developer",
               next_action: "continue_stream"
             })

    assert {:ok, rebuilt} = EventStore.rebuild_projections()

    assert rebuilt.attach_requests["run-rebuild"].event_type == "AttachRequested"
    assert List.last(rebuilt.interactive_recovery["run-rebuild"]).next_action == "continue_stream"
  end

  defp seed_pi_worker(run_id, worker_id) do
    assert {:ok, _} =
             WorkerProtocol.start_phase("developer", %{
               run_id: run_id,
               worker_id: worker_id,
               adapter: "pi_sdk",
               session_id: "session-#{run_id}"
             })

    assert {:ok, _} =
             WorkerProtocol.heartbeat(%{
               run_id: run_id,
               phase_id: "developer",
               worker_id: worker_id,
               session_id: "session-#{run_id}",
               attach: %{session_path: "/tmp/#{run_id}.jsonl"}
             })
  end

  defp seed_worker_events(attrs) do
    now = DateTime.utc_now()

    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "worker:#{attrs.run_id}:#{attrs.worker_id}",
               event_type: "WorkerStarted",
               payload: Map.merge(attrs, %{sequence: 0, observed_at: now}),
               metadata: %{correlation_id: attrs.run_id, idempotency_key: "start:#{attrs.run_id}"}
             })

    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "worker:#{attrs.run_id}:#{attrs.worker_id}",
               event_type: "WorkerHeartbeat",
               payload: Map.merge(attrs, %{sequence: 1, observed_at: now}),
               metadata: %{
                 correlation_id: attrs.run_id,
                 idempotency_key: "heartbeat:#{attrs.run_id}"
               }
             })
  end

  defp get_json(path) do
    :get
    |> conn(path)
    |> put_req_header("authorization", "Bearer secret")
    |> ForemanServer.Http.Router.call(@opts)
  end

  defp post_json(path, payload) do
    :post
    |> conn(path, Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer secret")
    |> ForemanServer.Http.Router.call(@opts)
  end
end
