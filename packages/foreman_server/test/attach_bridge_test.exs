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

    {:ok, tmp_dir: tmp_dir}
  end

  test "Pi SDK worker attach endpoint opens interactive attach mode" do
    task_pi_worker("run-attach", "worker-1")

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

  test "recently completed Pi SDK worker can attach but stale metadata is rejected" do
    task_pi_worker("run-completed", "worker-1")
    complete_run("run-completed")

    assert {:ok, %{result: recent}} = AttachBridge.request_attach(%{run_id: "run-completed"})
    assert recent.status == "ready"
    assert recent.session_id == "session-run-completed"

    task_worker_events(%{
      run_id: "run-stale",
      phase_id: "developer",
      worker_id: "worker-stale",
      adapter: "pi_sdk",
      session_id: "stale-session",
      attach: %{session_path: "/tmp/stale.jsonl"},
      observed_at: DateTime.add(DateTime.utc_now(), -120, :second)
    })

    assert {:ok, %{result: stale}} = AttachBridge.request_attach(%{run_id: "run-stale"})
    assert stale.status == "unsupported"
    assert stale.reason == "worker attach metadata is stale"
  end

  test "repeated attach GET is idempotent for same run worker" do
    task_pi_worker("run-idempotent", "worker-1")

    first = get_json("/api/v1/runs/run-idempotent/attach")
    second = get_json("/api/v1/runs/run-idempotent/attach")

    assert first.status == 200
    assert second.status == 200

    attach_events =
      "attach:run-idempotent"
      |> EventStore.stream()
      |> Enum.filter(&(&1.event_type == "AttachRequested"))

    assert length(attach_events) == 1
  end

  test "duplicate attach returns original matching worker after interleaved attach results" do
    task_pi_worker("run-idempotent-workers", "worker-1")
    task_pi_worker("run-idempotent-workers", "worker-2")

    first = get_json("/api/v1/runs/run-idempotent-workers/attach?worker_id=worker-1")
    second = get_json("/api/v1/runs/run-idempotent-workers/attach?worker_id=worker-2")
    third = get_json("/api/v1/runs/run-idempotent-workers/attach?worker_id=worker-1")

    assert first.status == 200
    assert second.status == 200
    assert third.status == 200
    assert Jason.decode!(first.resp_body)["attach"]["worker_id"] == "worker-1"
    assert Jason.decode!(second.resp_body)["attach"]["worker_id"] == "worker-2"
    assert Jason.decode!(third.resp_body)["attach"]["worker_id"] == "worker-1"

    missing = get_json("/api/v1/runs/run-idempotent-workers/attach?worker_id=missing-worker")
    fourth = get_json("/api/v1/runs/run-idempotent-workers/attach?worker_id=worker-1")

    assert Jason.decode!(missing.resp_body)["attach"]["status"] == "unsupported"
    assert Jason.decode!(fourth.resp_body)["attach"]["status"] == "ready"
    assert Jason.decode!(fourth.resp_body)["attach"]["worker_id"] == "worker-1"
  end

  test "unsupported duplicate attach returns original unsupported result after ready interleaving" do
    task_pi_worker("run-idempotent-unsupported", "worker-1")

    first_missing =
      get_json("/api/v1/runs/run-idempotent-unsupported/attach?worker_id=missing-worker")

    ready = get_json("/api/v1/runs/run-idempotent-unsupported/attach?worker_id=worker-1")

    second_missing =
      get_json("/api/v1/runs/run-idempotent-unsupported/attach?worker_id=missing-worker")

    assert Jason.decode!(first_missing.resp_body)["attach"]["status"] == "unsupported"
    assert Jason.decode!(ready.resp_body)["attach"]["status"] == "ready"
    assert Jason.decode!(second_missing.resp_body)["attach"]["status"] == "unsupported"
    assert Jason.decode!(second_missing.resp_body)["attach"]["worker_id"] == "missing-worker"
  end

  test "unsupported provider records reason and alternative commands" do
    task_worker_events(%{
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

  test "HTTP attach boundary covers auth unsupported provider and worker selection" do
    task_pi_worker("run-worker-select", "worker-selected")

    unauthorized =
      :get
      |> conn("/api/v1/runs/run-worker-select/attach")
      |> ForemanServer.Http.Router.call(@opts)

    assert unauthorized.status == 401

    selected = get_json("/api/v1/runs/run-worker-select/attach?worker_id=worker-selected")
    assert selected.status == 200
    assert Jason.decode!(selected.resp_body)["attach"]["worker_id"] == "worker-selected"

    missing = get_json("/api/v1/runs/run-worker-select/attach?worker_id=missing-worker")
    assert missing.status == 200
    assert Jason.decode!(missing.resp_body)["attach"]["reason"] =~ "no worker heartbeat"

    task_worker_events(%{
      run_id: "run-http-unsupported",
      phase_id: "developer",
      worker_id: "worker-unsupported",
      adapter: "mock",
      session_id: "mock-session",
      attach: %{session_path: "/tmp/mock.jsonl"}
    })

    unsupported = get_json("/api/v1/runs/run-http-unsupported/attach")
    assert unsupported.status == 200
    assert Jason.decode!(unsupported.resp_body)["attach"]["reason"] =~ "provider mock"
  end

  test "operator interrupt and resume records next recovery action" do
    task_pi_worker("run-interrupt", "worker-1")

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

  test "interrupt and resume reject unknown run phase and invalid recovery state before side effects" do
    before_events = EventStore.all()

    assert {:error, {:not_found, :run}} =
             AttachBridge.interrupt_phase(%{run_id: "missing-run", phase_id: "developer"})

    assert EventStore.all() == before_events

    task_pi_worker("run-invalid", "worker-1")

    assert {:error, {:not_found, :phase}} =
             AttachBridge.interrupt_phase(%{run_id: "run-invalid", phase_id: "reviewer"})

    assert {:error, {:conflict, :phase_not_interrupted}} =
             AttachBridge.resume_after_interrupt(%{
               run_id: "run-invalid",
               phase_id: "developer",
               next_action: "restart_phase"
             })

    unknown_run = post_json("/api/v1/runs/missing-run/interrupt", %{phase_id: "developer"})
    assert unknown_run.status == 404

    unknown_phase = post_json("/api/v1/runs/run-invalid/interrupt", %{phase_id: "reviewer"})
    assert unknown_phase.status == 404

    not_interrupted =
      post_json("/api/v1/runs/run-invalid/resume", %{
        phase_id: "developer",
        next_action: "restart_phase"
      })

    assert not_interrupted.status == 409
  end

  test "resume rejects terminal runs before side effects" do
    for status <- ["completed", "failed", "blocked"] do
      run_id = "run-terminal-#{status}"
      task_pi_worker(run_id, "worker-1")

      assert {:ok, _} =
               AttachBridge.interrupt_phase(%{run_id: run_id, phase_id: "developer"})

      terminal_run(run_id, status)
      before_events = EventStore.stream("attach:#{run_id}")

      assert {:error, {:conflict, {:run_not_active, ^status}}} =
               AttachBridge.resume_after_interrupt(%{
                 run_id: run_id,
                 phase_id: "developer",
                 next_action: "restart_phase"
               })

      assert EventStore.stream("attach:#{run_id}") == before_events
      snapshot = ProjectionStore.snapshot()
      expected_phase_status = if status == "blocked", do: "interrupted", else: status
      assert snapshot.runs[run_id].phase_status["developer"] == expected_phase_status
      refute snapshot.runs[run_id].recovery_next_action == "restart_phase"
    end
  end

  test "HTTP resume rejects terminal runs before side effects" do
    for status <- ["completed", "failed", "blocked"] do
      run_id = "run-http-terminal-#{status}"
      task_pi_worker(run_id, "worker-1")

      interrupt = post_json("/api/v1/runs/#{run_id}/interrupt", %{phase_id: "developer"})
      assert interrupt.status == 202

      terminal_run(run_id, status)
      before_events = EventStore.stream("attach:#{run_id}")

      resume =
        post_json("/api/v1/runs/#{run_id}/resume", %{
          phase_id: "developer",
          next_action: "restart_phase"
        })

      assert resume.status == 409
      assert EventStore.stream("attach:#{run_id}") == before_events
      expected_phase_status = if status == "blocked", do: "interrupted", else: status

      assert ProjectionStore.snapshot().runs[run_id].phase_status["developer"] ==
               expected_phase_status
    end
  end

  test "attach and recovery projections replay after server restart", %{tmp_dir: tmp_dir} do
    task_pi_worker("run-rebuild", "worker-1")
    assert {:ok, _} = AttachBridge.request_attach(%{run_id: "run-rebuild"})

    assert {:ok, _} =
             AttachBridge.interrupt_phase(%{run_id: "run-rebuild", phase_id: "developer"})

    assert {:ok, _} =
             AttachBridge.resume_after_interrupt(%{
               run_id: "run-rebuild",
               phase_id: "developer",
               next_action: "continue_stream"
             })

    restart_app(tmp_dir)

    snapshot = ProjectionStore.snapshot()
    assert snapshot.attach_requests["run-rebuild"].event_type == "AttachRequested"

    assert List.last(snapshot.interactive_recovery["run-rebuild"]).next_action ==
             "continue_stream"
  end

  defp task_pi_worker(run_id, worker_id) do
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

  defp task_worker_events(attrs) do
    now = Map.get(attrs, :observed_at, DateTime.utc_now())

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

  defp complete_run(run_id), do: terminal_run(run_id, "completed")

  defp terminal_run(run_id, "completed") do
    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "run:#{run_id}",
               event_type: "RunCompleted",
               payload: %{run_id: run_id, observed_at: DateTime.utc_now()},
               metadata: %{correlation_id: run_id, idempotency_key: "complete:#{run_id}"}
             })
  end

  defp terminal_run(run_id, "failed") do
    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "run:#{run_id}",
               event_type: "RunFailed",
               payload: %{run_id: run_id, reason: "test_failure", observed_at: DateTime.utc_now()},
               metadata: %{correlation_id: run_id, idempotency_key: "failed:#{run_id}"}
             })
  end

  defp terminal_run(run_id, "blocked") do
    assert {:ok, _} =
             EventStore.append(%{
               stream_id: "run:#{run_id}",
               event_type: "RunBlocked",
               payload: %{run_id: run_id, observed_at: DateTime.utc_now()},
               metadata: %{correlation_id: run_id, idempotency_key: "blocked:#{run_id}"}
             })
  end

  defp restart_app(tmp_dir) do
    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :auth_token, "secret")
    assert :ok = Application.start(:foreman_server)
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
