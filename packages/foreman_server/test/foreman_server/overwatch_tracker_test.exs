defmodule ForemanServer.Overwatch.TrackerTest do
  use ExUnit.Case, async: false

  alias ForemanServer.EventStore
  alias ForemanServer.Overwatch.Tracker

  setup do
    Application.stop(:foreman_server)

    path =
      Path.join(
        System.tmp_dir!(),
        "foreman-tracker-#{System.unique_integer([:positive])}.term.log"
      )

    Application.put_env(:foreman_server, :event_log_path, path)
    {:ok, _} = Application.ensure_all_started(:foreman_server)

    EventStore.append(%{
      stream_id: "task:task-1",
      event_type: "TaskCreated",
      payload: %{task_id: "task-1", project_id: "proj", title: "Task", status: "ready"},
      metadata: %{correlation_id: "test"}
    })

    EventStore.append(%{
      stream_id: "run:run-1",
      event_type: "RunStarted",
      payload: %{run_id: "run-1", task_id: "task-1", status: "in_progress"},
      metadata: %{correlation_id: "test"}
    })

    EventStore.append(%{
      stream_id: "worker:run-1:worker-1",
      event_type: "WorkerStarted",
      payload: %{
        run_id: "run-1",
        worker_id: "worker-1",
        phase_id: "explorer",
        sequence: 0,
        adapter: "default",
        project_id: "proj"
      },
      metadata: %{correlation_id: "test"}
    })

    on_exit(fn ->
      Application.stop(:foreman_server)
      File.rm(path)
    end)

    :ok
  end

  # ─── Basic track and heartbeat ────────────────────────────────────────────────

  test "track starts a worker entry with monitor and timer" do
    {:ok, worker_pid} = Agent.start_link(fn -> :ok end)
    :ok = Tracker.track(worker_pid, "run-1", "worker-1", "explorer", Agent)

    state = :sys.get_state(Tracker)
    key = {"run-1", "worker-1"}

    assert %{session_token: 1, heartbeat_gen: 0} = state.workers[key]
    assert is_reference(state.workers[key].monitor_ref)
    assert is_reference(state.workers[key].timer_ref)
    assert state.workers[key].worker_pid == worker_pid

    Agent.stop(worker_pid)
  end

  test "worker_heartbeat cancels old timer and starts new timer with incremented heartbeat_gen" do
    {:ok, worker_pid} = Agent.start_link(fn -> :ok end)
    :ok = Tracker.track(worker_pid, "run-1", "worker-1", "explorer", Agent)

    key = {"run-1", "worker-1"}
    %{timer_ref: old_ref, heartbeat_gen: 0} = :sys.get_state(Tracker).workers[key]

    :ok = Tracker.worker_heartbeat(worker_pid, "run-1", "worker-1", 1, DateTime.utc_now())

    %{timer_ref: new_ref, heartbeat_gen: 1} = :sys.get_state(Tracker).workers[key]
    assert new_ref != old_ref

    Agent.stop(worker_pid)
  end

  # ─── Re-track ────────────────────────────────────────────────────────────────

  test "re-track cancels prior timer and monitor and bumps session_token" do
    {:ok, worker_pid1} = Agent.start_link(fn -> :ok end)
    {:ok, worker_pid2} = Agent.start_link(fn -> :ok end)

    :ok = Tracker.track(worker_pid1, "run-1", "worker-1", "explorer", Agent)

    %{timer_ref: old_timer, monitor_ref: old_ref, session_token: 1} =
      :sys.get_state(Tracker).workers[{"run-1", "worker-1"}]

    :ok = Tracker.track(worker_pid2, "run-1", "worker-1", "explorer", Agent)

    %{timer_ref: new_timer, monitor_ref: new_ref, session_token: 2} =
      :sys.get_state(Tracker).workers[{"run-1", "worker-1"}]

    assert new_timer != old_timer
    assert new_ref != old_ref
    assert is_reference(new_timer)
    assert is_reference(new_ref)

    Agent.stop(worker_pid1)
    Agent.stop(worker_pid2)
  end

  # ─── Stale timeout after re-track ────────────────────────────────────────────

  test "stale timeout from previous worker (old session_token) is ignored after re-track" do
    {:ok, worker_pid1} = Agent.start_link(fn -> :ok end)
    {:ok, worker_pid2} = Agent.start_link(fn -> :ok end)

    :ok = Tracker.track(worker_pid1, "run-1", "worker-1", "explorer", Agent)

    key = {"run-1", "worker-1"}
    %{session_token: old_token} = :sys.get_state(Tracker).workers[key]

    :ok = Tracker.track(worker_pid2, "run-1", "worker-1", "explorer", Agent)

    send(Tracker, {:worker_timeout, key, old_token, 0})

    Process.sleep(10)

    assert %{session_token: 2} = :sys.get_state(Tracker).workers[key]

    Agent.stop(worker_pid1)
    Agent.stop(worker_pid2)
  end

  # ─── Stale pid heartbeat after re-track ──────────────────────────────────────

  test "stale heartbeat from old pid after re-track is ignored and does not reset timer" do
    {:ok, worker_pid1} = Agent.start_link(fn -> :ok end)
    {:ok, worker_pid2} = Agent.start_link(fn -> :ok end)

    :ok = Tracker.track(worker_pid1, "run-1", "worker-1", "explorer", Agent)

    key = {"run-1", "worker-1"}
    %{session_token: 1, heartbeat_gen: 0} = :sys.get_state(Tracker).workers[key]

    :ok = Tracker.track(worker_pid2, "run-1", "worker-1", "explorer", Agent)

    %{timer_ref: new_timer, session_token: 2, heartbeat_gen: 0} =
      :sys.get_state(Tracker).workers[key]

    # Send stale heartbeat from old pid — must be silently ignored.
    :ok = Tracker.worker_heartbeat(worker_pid1, "run-1", "worker-1", 1, DateTime.utc_now())

    # Timer and heartbeat_gen must be completely unchanged.
    %{timer_ref: unchanged_timer, heartbeat_gen: 0} =
      :sys.get_state(Tracker).workers[key]

    assert unchanged_timer == new_timer

    # No WorkerHeartbeat event must be appended for the stale pid.
    events = EventStore.stream("worker:run-1:worker-1")
    worker_heartbeat_count = Enum.count(events, &(&1.event_type == "WorkerHeartbeat"))

    assert worker_heartbeat_count == 0,
           "WorkerHeartbeat must not be emitted for stale pid, got #{worker_heartbeat_count} events"

    Agent.stop(worker_pid1)
    Agent.stop(worker_pid2)
  end

  # ─── DOWN handler ─────────────────────────────────────────────────────────────

  test "DOWN message removes worker and emits WorkerExited" do
    {:ok, worker_pid} = Agent.start_link(fn -> :ok end)
    :ok = Tracker.track(worker_pid, "run-1", "worker-1", "explorer", Agent)

    _ = :sys.get_state(Tracker).workers[{"run-1", "worker-1"}]

    Agent.stop(worker_pid)
    Process.sleep(50)

    refute Map.has_key?(:sys.get_state(Tracker).workers, {"run-1", "worker-1"})

    events = EventStore.stream("worker:run-1:worker-1")
    assert Enum.any?(events, &(&1.event_type == "WorkerExited"))
  end

  test "DOWN for unknown monitor ref is a silent no-op" do
    fake_ref = make_ref()
    send(Tracker, {:DOWN, fake_ref, :process, self(), :normal})

    Process.sleep(10)
    assert :sys.get_state(Tracker).workers == %{}
  end

  # ─── Heartbeat reset races ───────────────────────────────────────────────────

  test "stale timeout after heartbeat reset is ignored when heartbeat_gen differs" do
    {:ok, worker_pid} = Agent.start_link(fn -> :ok end)
    :ok = Tracker.track(worker_pid, "run-1", "worker-1", "explorer", Agent)

    key = {"run-1", "worker-1"}
    %{session_token: 1, heartbeat_gen: 0} = :sys.get_state(Tracker).workers[key]

    :ok = Tracker.worker_heartbeat(worker_pid, "run-1", "worker-1", 1, DateTime.utc_now())

    send(Tracker, {:worker_timeout, key, 1, 0})

    Process.sleep(10)

    assert Map.has_key?(:sys.get_state(Tracker).workers, key)

    Agent.stop(worker_pid)
  end

  # ─── Timeout: WorkerUnresponsive + WorkerRecoveryRequired emitted ─────────────────

  test "timeout message emits WorkerUnresponsive and WorkerRecoveryRequired, removes entry" do
    {:ok, worker_pid} = Agent.start_link(fn -> :ok end)
    :ok = Tracker.track(worker_pid, "run-1", "worker-1", "explorer", Agent)

    key = {"run-1", "worker-1"}
    %{session_token: 1, heartbeat_gen: 0} = :sys.get_state(Tracker).workers[key]

    send(Tracker, {:worker_timeout, key, 1, 0})
    Process.sleep(50)

    refute Map.has_key?(:sys.get_state(Tracker).workers, key)

    events = EventStore.stream("worker:run-1:worker-1")
    assert Enum.any?(events, &(&1.event_type == "WorkerUnresponsive"))

    recovery_events = EventStore.stream("recovery:run-1")
    assert Enum.any?(recovery_events, &(&1.event_type == "WorkerRecoveryRequired"))
    req = Enum.find(recovery_events, &(&1.event_type == "WorkerRecoveryRequired"))
    assert req.payload.phase_id == "explorer"

    Agent.stop(worker_pid)
  end

  test "timeout on already-terminal run emits neither WorkerUnresponsive nor WorkerRecoveryRequired" do
    # Mark run-1 as completed so WorkerProtocol.emit/2 rejects the event.
    {:ok, _} =
      ForemanServer.CommandRouter.handle(%{
        command_id: "complete-run-1",
        command_type: "run.complete",
        payload: %{run_id: "run-1"}
      })

    {:ok, worker_pid} = Agent.start_link(fn -> :ok end)
    :ok = Tracker.track(worker_pid, "run-1", "worker-1", "explorer", Agent)

    key = {"run-1", "worker-1"}
    send(Tracker, {:worker_timeout, key, 1, 0})
    Process.sleep(50)

    # Worker entry still cleaned up.
    refute Map.has_key?(:sys.get_state(Tracker).workers, key)

    # WorkerUnresponsive was rejected: run is terminal, WorkerProtocol.emit/2 returns
    # {:error, {:run_not_active, _}} and emits nothing.
    events = EventStore.stream("worker:run-1:worker-1")
    refute Enum.any?(events, &(&1.event_type == "WorkerUnresponsive"))

    # No WorkerRecoveryRequired either — gating on {:ok, _} prevents dispatch.
    recovery_events = EventStore.stream("recovery:run-1")
    refute Enum.any?(recovery_events, &(&1.event_type == "WorkerRecoveryRequired"))

    Agent.stop(worker_pid)
  end

  # ─── Re-track after crash ────────────────────────────────────────────────────

  test "worker crash followed by re-track: stale DOWN (old monitor ref) is ignored" do
    {:ok, worker_pid1} = Agent.start_link(fn -> :ok end)
    :ok = Tracker.track(worker_pid1, "run-1", "worker-1", "explorer", Agent)

    %{monitor_ref: old_ref} = :sys.get_state(Tracker).workers[{"run-1", "worker-1"}]

    {:ok, worker_pid2} = Agent.start_link(fn -> :ok end)
    :ok = Tracker.track(worker_pid2, "run-1", "worker-1", "explorer", Agent)

    %{session_token: 2, monitor_ref: new_ref} =
      :sys.get_state(Tracker).workers[{"run-1", "worker-1"}]

    assert new_ref != old_ref

    # Stale DOWN for the old monitor ref — must be silently ignored.
    send(Tracker, {:DOWN, old_ref, :process, worker_pid1, :killed})
    Process.sleep(50)

    assert Map.has_key?(:sys.get_state(Tracker).workers, {"run-1", "worker-1"})

    Agent.stop(worker_pid1)
    Agent.stop(worker_pid2)
  end
end
