defmodule ForemanServer.SchedulerTest.NoopLauncher do
  def launch(_task, run_id, phases), do: {:ok, %{run_id: run_id, phases: phases}}
end

defmodule ForemanServer.SchedulerTest do
  use ExUnit.Case

  alias ForemanServer.{EventStore, ProjectionStore, Scheduler}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-scheduler-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))

    Application.put_env(:foreman_server, :scheduler,
      auto_tick: false,
      event_triggered_ticks: false,
      worker_launcher: ForemanServer.SchedulerTest.NoopLauncher
    )

    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      Application.delete_env(:foreman_server, :scheduler)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "tick claims ready tasks and records run start without synthetic phases" do
    create_task("task-a", %{project_id: "alpha", status: "ready"})

    assert {:ok, %{claimed: [%{task_id: "task-a", run_id: run_id}], skipped: []}} =
             Scheduler.tick(max_concurrent: 2, default_phases: ["dev", "qa"])

    assert run_id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    assert ProjectionStore.snapshot().tasks["task-a"].status == "in_progress"

    assert [%{event_type: "RunStarted", payload: payload}] = EventStore.stream("run:#{run_id}")
    assert payload.phase_order == ["dev", "qa"]

    assert [%{event_type: "ScheduledFireRecorded", payload: fire_payload}] =
             EventStore.stream("scheduler_fire:#{run_id}")

    assert fire_payload.run_id == run_id
    assert ProjectionStore.snapshot().scheduler_intents[run_id].status == "recorded"
    refute Enum.any?(EventStore.stream("run:#{run_id}"), &(&1.event_type == "PhaseStarted"))
  end

  test "confirm_execution/1 appends scheduled fire confirmation for worker pickup" do
    create_task("task-confirm-runtime", %{project_id: "alpha", status: "ready"})

    assert {:ok, %{claimed: [%{run_id: run_id}]}} = Scheduler.tick(default_phases: ["dev"])

    assert {:ok, _confirmed} =
             Scheduler.confirm_execution(%{
               run_id: run_id,
               worker_id: "worker-dev",
               phase_id: "dev"
             })

    intent = ProjectionStore.snapshot().scheduler_intents[run_id]
    assert intent.status == "confirmed"

    assert Enum.map(intent.history, & &1.event_type) == [
             "ScheduledFireRecorded",
             "ScheduledFireConfirmed"
           ]
  end

  test "global capacity leaves extra ready tasks queued and records skip reason" do
    create_task("task-a", %{project_id: "test", status: "ready"})
    create_task("task-b", %{project_id: "test", status: "ready"})

    assert {:ok, %{claimed: [%{task_id: "task-a"}], skipped: [%{task_id: "task-b"}]}} =
             ForemanServer.scheduler_tick(max_concurrent: 1)

    snapshot = ProjectionStore.snapshot()
    assert snapshot.tasks["task-b"].status == "ready"
    assert snapshot.scheduler_skips["task-b"].reason == "global_capacity_exhausted"
  end

  test "project capacity limits are enforced across scheduler callers" do
    create_task("alpha-1", %{project_id: "alpha", status: "ready"})
    create_task("alpha-2", %{project_id: "alpha", status: "ready"})
    create_task("beta-1", %{project_id: "beta", status: "ready"})

    assert {:ok, result} = Scheduler.tick(max_concurrent: 3, project_limits: %{"alpha" => 1})

    assert Enum.map(result.claimed, & &1.task_id) == ["alpha-1", "beta-1"]

    assert result.skipped == [
             %{task_id: "alpha-2", project_id: "alpha", reason: "project_capacity_exhausted"}
           ]

    snapshot = ProjectionStore.snapshot()
    assert snapshot.tasks["alpha-2"].status == "ready"
    assert snapshot.scheduler_skips["alpha-2"].reason == "project_capacity_exhausted"
  end

  test "scheduler dispatches through CommandRouter and respects project run-limit cap" do
    project_id = "cap-proj-#{System.unique_integer([:positive])}"

    # Prime the project with 100 active runs directly via the router so the
    # scheduler's `claim_task` is the 101st attempt.
    Enum.each(1..100, fn i ->
      run_id = "cap-run-#{System.unique_integer([:positive])}-#{i}"

      {:ok, _} =
        ForemanServer.CommandRouter.handle(%{
          command_id: "cap-seed:#{run_id}",
          command_type: "run.start",
          payload: %{run_id: run_id, project_id: project_id}
        })
    end)

    create_task("task-over-cap", %{project_id: project_id, status: "ready"})

    assert {:ok, %{claimed: [], skipped: [%{task_id: "task-over-cap", reason: reason}]}} =
             Scheduler.tick(default_phases: ["dev"], max_concurrent: 1)

    assert reason =~ "run_limit_exceeded"
    assert ProjectionStore.snapshot().tasks["task-over-cap"].status == "ready"
  end

  test "periodic tick automatically claims ready tasks" do
    Application.stop(:foreman_server)

    Application.put_env(:foreman_server, :scheduler,
      auto_tick: true,
      event_triggered_ticks: false,
      tick_interval_ms: 20,
      worker_launcher: ForemanServer.SchedulerTest.NoopLauncher
    )

    assert :ok = Application.start(:foreman_server)

    create_task("task-auto", %{project_id: "alpha", status: "ready"})

    assert_receive_tick(fn -> ProjectionStore.snapshot().tasks["task-auto"].status end)
    run_id = ProjectionStore.snapshot().tasks["task-auto"].run_id
    assert [%{event_type: "RunStarted"}] = EventStore.stream("run:#{run_id}")
  end

  test "event appended to ready task stream triggers scheduler without projection polling tick" do
    Application.stop(:foreman_server)

    Application.put_env(:foreman_server, :scheduler,
      auto_tick: false,
      event_triggered_ticks: true,
      worker_launcher: ForemanServer.SchedulerTest.NoopLauncher
    )

    assert :ok = Application.start(:foreman_server)

    assert {:ok, _event} =
             ForemanServer.EventStore.append(%{
               stream_id: "task:task-event",
               event_type: "TaskCreated",
               payload: %{
                 task_id: "task-event",
                 title: "event task",
                 project_id: "alpha",
                 status: "ready"
               },
               metadata: %{correlation_id: "task-event", idempotency_key: "task-event-create"}
             })

    assert_receive_tick(fn -> ProjectionStore.snapshot().tasks["task-event"].status end)
    assert run_id = ProjectionStore.snapshot().tasks["task-event"].run_id
    assert [%{event_type: "RunStarted"}] = EventStore.stream("run:#{run_id}")
    assert Scheduler.state().last_event_id
  end

  defp assert_receive_tick(fun, attempts \\ 20)

  defp assert_receive_tick(fun, attempts) when attempts > 0 do
    if fun.() == "in_progress" do
      :ok
    else
      Process.sleep(10)
      assert_receive_tick(fun, attempts - 1)
    end
  end

  defp assert_receive_tick(_fun, 0), do: flunk("scheduler did not claim ready task")

  defp create_task(task_id, attrs) do
    payload = Map.merge(%{task_id: task_id, title: task_id}, attrs)

    assert {:ok, _} =
             ForemanServer.handle_command(%{
               command_id: "cmd-#{task_id}",
               command_type: "task.create",
               payload: payload
             })
  end
end
