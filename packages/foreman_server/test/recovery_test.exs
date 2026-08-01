defmodule ForemanServer.RecoveryTest.NoopLauncher do
  def launch(_task, run_id, phases), do: {:ok, %{run_id: run_id, phases: phases}}
end

defmodule ForemanServer.RecoveryTest.TrackingLauncher do
  def launch(task, run_id, phases) do
    if pid = Application.get_env(:foreman_server, :recovery_test_pid) do
      send(pid, {:launch, Map.get(task, :task_id), run_id, phases})
    end

    {:ok, %{run_id: run_id, phases: phases}}
  end
end

defmodule ForemanServer.RecoveryTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, ProjectionStore, Recovery, Scheduler}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-recovery-scan-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    restart_app!(tmp_dir)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :project_store_path)
      Application.delete_env(:foreman_server, :scheduler)
      Application.delete_env(:foreman_server, :recovery_test_pid)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    %{tmp_dir: tmp_dir}
  end

  test "startup scan emits RunRecoveryEvent for interrupted runs and dedupes repeated detect in same boot", %{tmp_dir: tmp_dir} do
    task_id = "task-interrupted"
    run_id = "run-interrupted"

    create_task(task_id, %{project_id: "alpha", status: "ready"})
    append_task_updated(task_id, %{status: "in_progress", run_id: run_id})
    append_run_started(run_id, task_id, ["dev"])

    restart_app!(tmp_dir)

    assert_eventually(fn ->
      recoveries = Map.get(ProjectionStore.snapshot().run_recoveries, run_id, [])
      length(recoveries) == 1 and Enum.any?(recoveries, &(&1.outcome == "interrupted_run_detected"))
    end)

    assert {:ok, _result} = Recovery.detect()

    recoveries = Map.get(ProjectionStore.snapshot().run_recoveries, run_id, [])
    assert Enum.count(recoveries, &(&1.outcome == "interrupted_run_detected")) == 1
  end

  test "restart re-dispatches stale scheduled fire exactly once per boot", %{tmp_dir: tmp_dir} do
    create_task("task-redispatch", %{project_id: "alpha", status: "ready"})

    assert {:ok, %{claimed: [%{run_id: run_id}]}} =
             Scheduler.tick(default_phases: ["dev", "qa"])

    assert ProjectionStore.snapshot().scheduler_intents[run_id].status == "recorded"

    restart_app!(tmp_dir,
      worker_launcher: ForemanServer.RecoveryTest.TrackingLauncher,
      recovery_test_pid: self()
    )

    assert_receive {:launch, "task-redispatch", ^run_id, ["dev", "qa"]}, 500

    assert_eventually(fn ->
      intent = ProjectionStore.snapshot().scheduler_intents[run_id]

      intent.status == "recorded" and
        intent.attempt == 2 and
        Enum.map(intent.history, & &1.event_type) == [
          "ScheduledFireRecorded",
          "SchedulerIntentStale",
          "ScheduledFireRecorded"
        ]
    end)

    assert_eventually(fn ->
      recoveries = Map.get(ProjectionStore.snapshot().run_recoveries, run_id, [])
      Enum.any?(recoveries, &(&1.outcome == "scheduled_fire_redispatched"))
    end)

    assert {:ok, %{redispatched: 0, skipped: 0}} = Recovery.detect_unconfirmed_intents()
    refute_receive {:launch, "task-redispatch", ^run_id, ["dev", "qa"]}, 100

    recorded_events =
      EventStore.stream("scheduler_fire:#{run_id}")
      |> Enum.count(&(&1.event_type == "ScheduledFireRecorded"))

    assert recorded_events == 2

    recovery_pid = Process.whereis(Recovery)
    Process.exit(recovery_pid, :kill)

    assert_eventually(fn ->
      restarted_pid = Process.whereis(Recovery)
      is_pid(restarted_pid) and restarted_pid != recovery_pid
    end)

    refute_receive {:launch, "task-redispatch", ^run_id, ["dev", "qa"]}, 150

    recorded_events_after_restart =
      EventStore.stream("scheduler_fire:#{run_id}")
      |> Enum.count(&(&1.event_type == "ScheduledFireRecorded"))

    assert recorded_events_after_restart == 2

  end

  test "restart re-dispatches pre-seeded stale intents from an earlier boot", %{tmp_dir: tmp_dir} do
    create_task("task-preseeded-stale", %{project_id: "alpha", status: "ready"})

    assert {:ok, %{claimed: [%{run_id: run_id}]}} = Scheduler.tick(default_phases: ["dev"])

    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "scheduler_fire:#{run_id}",
               event_type: "SchedulerIntentStale",
               payload: %{fire_id: run_id, run_id: run_id, task_id: "task-preseeded-stale", attempt: 1},
               metadata: %{correlation_id: run_id, idempotency_key: "intent-stale:seed:#{run_id}"}
             })

    restart_app!(tmp_dir,
      worker_launcher: ForemanServer.RecoveryTest.TrackingLauncher,
      recovery_test_pid: self()
    )

    assert_receive {:launch, "task-preseeded-stale", ^run_id, ["dev"]}, 500

    assert_eventually(fn ->
      intent = ProjectionStore.snapshot().scheduler_intents[run_id]

      intent.status == "recorded" and
        intent.attempt == 2 and
        Enum.map(intent.history, & &1.event_type) == [
          "ScheduledFireRecorded",
          "SchedulerIntentStale",
          "SchedulerIntentStale",
          "ScheduledFireRecorded"
        ]
    end)

    assert_eventually(fn ->
      recoveries = Map.get(ProjectionStore.snapshot().run_recoveries, run_id, [])
      Enum.any?(recoveries, &(&1.outcome == "scheduled_fire_redispatched"))
    end)
  end


  test "worker pickup confirms scheduled fire intent" do
    create_task("task-confirm", %{project_id: "alpha", status: "ready"})

    assert {:ok, %{claimed: [%{run_id: run_id}]}} = Scheduler.tick(default_phases: ["dev"])

    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "worker:#{run_id}:worker-dev",
               event_type: "WorkerStarted",
               payload: %{run_id: run_id, worker_id: "worker-dev", phase_id: "dev", sequence: 0},
               metadata: %{correlation_id: run_id, idempotency_key: "worker-start:#{run_id}:worker-dev"}
             })

    assert_eventually(fn ->
      intent = ProjectionStore.snapshot().scheduler_intents[run_id]

      intent.status == "confirmed" and
        Enum.map(intent.history, & &1.event_type) == [
          "ScheduledFireRecorded",
          "ScheduledFireConfirmed"
        ]
    end)
  end

  test "restart skips stale scheduled fire when the run was already abandoned", %{tmp_dir: tmp_dir} do
    create_task("task-skipped", %{project_id: "alpha", status: "ready"})

    assert {:ok, %{claimed: [%{run_id: run_id}]}} = Scheduler.tick(default_phases: ["dev"])

    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "run:#{run_id}",
               event_type: "RunCompleted",
               payload: %{run_id: run_id, task_id: "task-skipped", phase_id: "dev"},
               metadata: %{correlation_id: run_id, idempotency_key: "run-completed:#{run_id}"}
             })

    restart_app!(tmp_dir,
      worker_launcher: ForemanServer.RecoveryTest.TrackingLauncher,
      recovery_test_pid: self()
    )

    refute_receive {:launch, "task-skipped", ^run_id, _phases}, 150

    assert_eventually(fn ->
      intent = ProjectionStore.snapshot().scheduler_intents[run_id]

      intent.status == "skipped" and
        Enum.map(intent.history, & &1.event_type) == [
          "ScheduledFireRecorded",
          "SchedulerIntentStale",
          "ScheduledFireSkipped"
        ]
    end)

    assert_eventually(fn ->
      recoveries = Map.get(ProjectionStore.snapshot().run_recoveries, run_id, [])
      Enum.any?(recoveries, &(&1.outcome == "scheduled_fire_skipped" and &1.reason == "run_completed"))
    end)
  end

  defp restart_app!(tmp_dir, opts \\ []) do
    _ = Application.stop(:foreman_server)

    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    Application.put_env(:foreman_server, :project_store_path, Path.join(tmp_dir, "projects.term"))

    worker_launcher =
      Keyword.get(opts, :worker_launcher, ForemanServer.RecoveryTest.NoopLauncher)

    Application.put_env(:foreman_server, :scheduler,
      auto_tick: false,
      event_triggered_ticks: false,
      worker_launcher: worker_launcher
    )

    case Keyword.fetch(opts, :recovery_test_pid) do
      {:ok, pid} -> Application.put_env(:foreman_server, :recovery_test_pid, pid)
      :error -> Application.delete_env(:foreman_server, :recovery_test_pid)
    end

    assert :ok = Application.start(:foreman_server)
  end

  defp create_task(task_id, attrs) do
    payload = Map.merge(%{task_id: task_id, title: task_id}, attrs)

    assert {:ok, _result} =
             ForemanServer.handle_command(%{
               command_id: "task-create:#{task_id}",
               command_type: "task.create",
               payload: payload
             })
  end

  defp append_task_updated(task_id, payload) do
    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "task:#{task_id}",
               event_type: "TaskUpdated",
               payload: Map.put(payload, :task_id, task_id),
               metadata: %{correlation_id: task_id, idempotency_key: "task-update:#{task_id}:#{inspect(payload)}"}
             })
  end

  defp append_run_started(run_id, task_id, phase_order) do
    assert {:ok, _event} =
             EventStore.append(%{
               stream_id: "run:#{run_id}",
               event_type: "RunStarted",
               payload: %{
                 run_id: run_id,
                 task_id: task_id,
                 phase_order: phase_order,
                 workflow: "feature"
               },
               metadata: %{correlation_id: run_id, idempotency_key: "run-started:#{run_id}"}
             })
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition not satisfied")
end
