defmodule ForemanServer.SchedulerTest.NoopLauncher do
  def launch(_task, run_id, phases), do: {:ok, %{run_id: run_id, phases: phases}}
end

defmodule ForemanServer.SchedulerTest do
  use ExUnit.Case

  alias ForemanServer.{ProjectionStore, RunActor, Scheduler}

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

  test "tick claims ready tasks and starts run actors when capacity exists" do
    create_task("task-a", %{project_id: "alpha", status: "ready"})

    assert {:ok, %{claimed: [%{task_id: "task-a", run_id: run_id}], skipped: []}} =
             Scheduler.tick(max_concurrent: 2, default_phases: ["dev", "qa"])

    assert run_id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
    assert %{current_phase: "dev", phase_order: ["dev", "qa"]} = RunActor.state(run_id)
    assert ProjectionStore.snapshot().tasks["task-a"].status == "in_progress"
  end

  test "global capacity leaves extra ready tasks queued and records skip reason" do
    create_task("task-a", %{status: "ready"})
    create_task("task-b", %{status: "ready"})

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
    assert %{current_phase: "developer"} = RunActor.state(run_id)
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
    assert %{current_phase: "developer"} = RunActor.state(run_id)
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
