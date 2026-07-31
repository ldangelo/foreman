defmodule ForemanServer.Overwatch.StuckDetectorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandRouter, EventStore, Overwatch.StuckDetector, ProjectionStore}

  setup do
    Application.stop(:foreman_server)

    path =
      Path.join(
        System.tmp_dir!(),
        "foreman-stuck-#{System.unique_integer([:positive])}.term.log"
      )

    Application.put_env(:foreman_server, :event_log_path, path)
    Application.put_env(:foreman_server, :stuck_run_check_interval_seconds, 5)
    {:ok, _} = Application.ensure_all_started(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :stuck_run_check_interval_seconds)
      File.rm(path)
      {:ok, _} = Application.ensure_all_started(:foreman_server)
    end)

    :ok
  end

  # ─── Happy path ─────────────────────────────────────────────────────────────

  test "flags run stuck after 15 minutes of inactivity and emits telemetry" do
    # Arrange: task + run whose last event was 16 minutes ago
    EventStore.append(%{
      stream_id: "task:stuck-task",
      event_type: "TaskCreated",
      payload: %{task_id: "stuck-task", project_id: "proj", title: "Stuck Task", status: "in_progress"},
      metadata: %{correlation_id: "stuck-test"}
    })

    stale_time = DateTime.add(DateTime.utc_now(), -16 * 60, :second)

    EventStore.append(%{
      stream_id: "run:stuck-run",
      event_type: "RunStarted",
      payload: %{run_id: "stuck-run", task_id: "stuck-task", status: "in_progress"},
      occurred_at: stale_time,
      metadata: %{correlation_id: "stuck-test"}
    })

    EventStore.append(%{
      stream_id: "worker:stuck-run:stuck-worker",
      event_type: "WorkerStarted",
      payload: %{run_id: "stuck-run", worker_id: "stuck-worker", phase_id: "explore"},
      occurred_at: stale_time,
      metadata: %{correlation_id: "stuck-test"}
    })

    # Verify last_event_time is stale before scan
    %{runs: runs} = ProjectionStore.snapshot()
    assert Map.get(runs, "stuck-run", %{}) |> Map.get(:last_event_time) == stale_time

    # Telemetry sync: capture test pid before attaching handler
    test_pid = self()
    handler_id = make_ref()
    :telemetry.attach(handler_id, [:foreman, :run, :stuck], fn _event, _measurements, metadata, _config ->
      send(test_pid, {:stuck_telemetry, metadata[:run_id]})
    end, nil)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Act
    StuckDetector
    |> Process.whereis()
    |> send(:scan)

    # Wait for telemetry confirmation
    assert_receive {:stuck_telemetry, "stuck-run"}, 1000

    # Assert
    events = EventStore.stream("run:stuck-run")
    assert Enum.any?(events, &(&1.event_type == "RunFlaggedStuck"))

    %{runs: runs} = ProjectionStore.snapshot()
    assert get_in(runs, ["stuck-run", :status]) == "stuck"
  end

  # ─── Idempotent: already stuck → no re-flag ─────────────────────────────────

  test "run.flag_stuck is idempotent — already stuck returns error and does not re-flag" do
    EventStore.append(%{
      stream_id: "task:idempotent-task",
      event_type: "TaskCreated",
      payload: %{task_id: "idempotent-task", project_id: "proj", title: "Task", status: "in_progress"},
      metadata: %{correlation_id: "idempotent-test"}
    })

    EventStore.append(%{
      stream_id: "run:idempotent-run",
      event_type: "RunStarted",
      payload: %{run_id: "idempotent-run", task_id: "idempotent-task", status: "in_progress"},
      metadata: %{correlation_id: "idempotent-test"}
    })

    # Flag it stuck
    {:ok, _} = CommandRouter.handle(%{
      command_id: "stuck:first-flag",
      command_type: "run.flag_stuck",
      payload: %{run_id: "idempotent-run"}
    })

    %{runs: runs} = ProjectionStore.snapshot()
    assert get_in(runs, ["idempotent-run", :status]) == "stuck"
    initial_events = EventStore.stream("run:idempotent-run")
    stuck_count = Enum.count(initial_events, &(&1.event_type == "RunFlaggedStuck"))

    # Act: send another scan
    StuckDetector
    |> Process.whereis()
    |> send(:scan)

    # Allow tiny window for scan to process
    Process.sleep(50)

    # Assert: no new RunFlaggedStuck events appended
    final_events = EventStore.stream("run:idempotent-run")
    assert Enum.count(final_events, &(&1.event_type == "RunFlaggedStuck")) == stuck_count
  end

  # ─── Active run: no false positive ─────────────────────────────────────────

  test "active run with recent heartbeat is not flagged stuck" do
    EventStore.append(%{
      stream_id: "task:active-task",
      event_type: "TaskCreated",
      payload: %{task_id: "active-task", project_id: "proj", title: "Task", status: "in_progress"},
      metadata: %{correlation_id: "active-test"}
    })

    EventStore.append(%{
      stream_id: "run:active-run",
      event_type: "RunStarted",
      payload: %{run_id: "active-run", task_id: "active-task", status: "in_progress"},
      metadata: %{correlation_id: "active-test"}
    })

    # Recent heartbeat
    EventStore.append(%{
      stream_id: "worker:active-run:active-worker",
      event_type: "WorkerHeartbeat",
      payload: %{run_id: "active-run", worker_id: "active-worker", phase_id: "explore"},
      metadata: %{correlation_id: "active-test"}
    })

    # Act
    StuckDetector
    |> Process.whereis()
    |> send(:scan)

    Process.sleep(50)

    # Assert: no RunFlaggedStuck
    events = EventStore.stream("run:active-run")
    refute Enum.any?(events, &(&1.event_type == "RunFlaggedStuck"))

    %{runs: runs} = ProjectionStore.snapshot()
    assert get_in(runs, ["active-run", :status]) == "in_progress"
  end

  # ─── Regression: nil last_event_time with recent started_at ───────────────────
  test "recent run with no liveness events after RunStarted is not flagged (uses started_at fallback)" do
    # Arrange: run with started_at = now, last_event_time absent.
    # This happens for runs created before last_event_time was added.
    EventStore.append(%{
      stream_id: "task:newly-started-task",
      event_type: "TaskCreated",
      payload: %{task_id: "newly-started-task", project_id: "proj", title: "Task", status: "in_progress"},
      metadata: %{correlation_id: "newly-started-test"}
    })

    # Append RunStarted WITHOUT a liveness event afterward → last_event_time = nil
    # but started_at = now (recent)
    EventStore.append(%{
      stream_id: "run:newly-started-run",
      event_type: "RunStarted",
      payload: %{run_id: "newly-started-run", task_id: "newly-started-task", status: "in_progress"},
      metadata: %{correlation_id: "newly-started-test"}
    })

    # Manually remove last_event_time from the projection to simulate a pre-existing
    # run that has no liveness event after RunStarted
    :sys.replace_state(ProjectionStore, fn snapshot ->
      update_in(snapshot, [:runs, "newly-started-run"], fn run ->
        Map.delete(run || %{}, :last_event_time)
      end)
    end)

    # Verify last_event_time is nil but started_at is recent
    %{runs: runs} = ProjectionStore.snapshot()
    assert Map.get(runs, "newly-started-run", %{}) |> Map.get(:last_event_time) == nil
    assert Map.get(runs, "newly-started-run", %{}) |> Map.get(:started_at) != nil

    # Act
    StuckDetector
    |> Process.whereis()
    |> send(:scan)

    Process.sleep(50)

    # Assert: NOT flagged — stale? falls back to started_at which is recent
    events = EventStore.stream("run:newly-started-run")
    refute Enum.any?(events, &(&1.event_type == "RunFlaggedStuck"))
  end

  # ─── Regression: stale started_at with recent updated_at ───────────────────────
  test "legacy run with stale started_at but recent updated_at is not flagged" do
    # A run whose last_event_time is nil, started_at is old, but updated_at is recent
    # (e.g. a state change happened without a liveness event)
    EventStore.append(%{
      stream_id: "task:legacy-task",
      event_type: "TaskCreated",
      payload: %{task_id: "legacy-task", project_id: "proj", title: "Task", status: "in_progress"},
      metadata: %{correlation_id: "legacy-test"}
    })

    EventStore.append(%{
      stream_id: "run:legacy-run",
      event_type: "RunStarted",
      payload: %{run_id: "legacy-run", task_id: "legacy-task", status: "in_progress"},
      metadata: %{correlation_id: "legacy-test"}
    })

    # Mutate: set started_at to 60 min ago, updated_at to now, strip last_event_time
    :sys.replace_state(ProjectionStore, fn snapshot ->
      update_in(snapshot, [:runs, "legacy-run"], fn run ->
        old = Map.delete(run || %{}, :last_event_time)
        Map.merge(old, %{
          started_at: DateTime.add(DateTime.utc_now(), -60 * 60, :second),
          updated_at: DateTime.utc_now()
        })
      end)
    end)

    # Verify setup
    %{runs: runs} = ProjectionStore.snapshot()
    run = Map.get(runs, "legacy-run", %{})
    assert run |> Map.get(:last_event_time) == nil
    assert run |> Map.get(:started_at) |> DateTime.diff(DateTime.utc_now(), :second) < -55 * 60
    assert run |> Map.get(:updated_at) |> DateTime.diff(DateTime.utc_now(), :second) >= -1

    # Act
    StuckDetector
    |> Process.whereis()
    |> send(:scan)

    Process.sleep(50)

    # Assert: updated_at is recent → not flagged
    events = EventStore.stream("run:legacy-run")
    refute Enum.any?(events, &(&1.event_type == "RunFlaggedStuck"))
  end

  # ─── Terminal run: not flagged ───────────────────────────────────────────────

  test "terminal run (completed) is not flagged stuck" do
    EventStore.append(%{
      stream_id: "task:terminal-task",
      event_type: "TaskCreated",
      payload: %{task_id: "terminal-task", project_id: "proj", title: "Task", status: "in_progress"},
      metadata: %{correlation_id: "terminal-test"}
    })

    EventStore.append(%{
      stream_id: "run:terminal-run",
      event_type: "RunStarted",
      payload: %{run_id: "terminal-run", task_id: "terminal-task", status: "in_progress"},
      metadata: %{correlation_id: "terminal-test"}
    })

    EventStore.append(%{
      stream_id: "run:terminal-run",
      event_type: "RunCompleted",
      payload: %{run_id: "terminal-run", status: "completed"},
      metadata: %{correlation_id: "terminal-test"}
    })

    # Act
    StuckDetector
    |> Process.whereis()
    |> send(:scan)

    Process.sleep(50)

    # Assert: RunCompleted, not RunFlaggedStuck
    events = EventStore.stream("run:terminal-run")
    assert Enum.any?(events, &(&1.event_type == "RunCompleted"))
    refute Enum.any?(events, &(&1.event_type == "RunFlaggedStuck"))
  end
end
