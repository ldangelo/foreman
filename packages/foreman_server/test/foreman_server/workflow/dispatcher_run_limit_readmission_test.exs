defmodule ForemanServer.Workflow.DispatcherRunLimitReadmissionTest do
  # Live acceptance F2 (foreman-s19h6): with `max_concurrent_runs: 1` the second
  # submitted task is refused (`run_limit_exceeded`) and must be admitted later,
  # either when capacity frees (the running run finishes) or when the limit is
  # raised. Exercised against the real Dispatcher, RunAdmission and projection.
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, CommandRouter, ProjectionStore}
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.RunSlotsReset

  setup do
    # Other files may have left the app-level Dispatcher stopped, suspended or
    # unsubscribed; this test needs the real, subscribed one.
    ForemanServer.TestSupport.DispatcherRestart.restart!()

    # Other files leave holders in the process-wide global slot aggregate; a
    # full slot would queue the first run instead of admitting it.
    RunSlotsReset.reset!()

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run_slots.acquire",
        command_id: "test:readmit-init:#{System.unique_integer([:positive])}",
        aggregate_id: "run_slots:global",
        payload: %{run_id: "readmit-init-#{System.unique_integer([:positive])}", capacity: 100}
      })

    :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link])
    test = self()

    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn run_id, _task ->
      send(test, {:run_supervisor_start, run_id})
      {:ok, :child}
    end)

    on_exit(fn ->
      if :meck.validate(ForemanServer.Workflow.RunSupervisor),
        do: :meck.unload(ForemanServer.Workflow.RunSupervisor)
    end)

    H.subscribe!()
    project = H.register_project(System.tmp_dir!(), config: %{})

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.update",
        aggregate_id: "project:#{project}",
        command_id: "u-#{System.unique_integer([:positive])}",
        payload: %{project_id: project, max_concurrent_runs: 1}
      })

    {:ok, project: project}
  end

  defp await_deferred(task_id) do
    receive do
      {:projection_event, %{event_type: "ProjectAdmissionDeferred", data: %{task_id: ^task_id}}} ->
        :ok

      {:projection_event, _other} ->
        await_deferred(task_id)
    after
      10_000 -> flunk("task #{task_id} was never deferred")
    end
  end

  defp submit(project) do
    task_id = "task-#{System.unique_integer([:positive])}"

    assert {:ok, %{"payload" => %{"run_id" => run_id}}} =
             CommandGateway.dispatch_operator(%{
               command_id: "c-#{System.unique_integer([:positive])}",
               aggregate_id: "task:#{task_id}",
               type: "task.create",
               payload: %{
                 task_id: task_id,
                 project_id: project,
                 task_type: "implement",
                 title: "t",
                 prompt: "p",
                 provider_tracked: false,
                 auto_approve: true
               }
             })

    {task_id, run_id}
  end

  test "a run-limit-deferred task starts after the limit is raised", %{project: project} do
    {_t1, run1} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000

    {t2, run2} = submit(project)
    await_deferred(t2)
    assert %{deferred_tasks: 1} = ProjectionStore.project_limits(project)
    refute_received {:run_supervisor_start, ^run2}

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "project.update",
        aggregate_id: "project:#{project}",
        command_id: "u-#{System.unique_integer([:positive])}",
        payload: %{project_id: project, max_concurrent_runs: 2}
      })

    assert_receive {:run_supervisor_start, ^run2}, 10_000
    assert %{deferred_tasks: 0} = ProjectionStore.project_limits(project)
  end

  test "a deferred run id is readable as deferred (not a 404) until it is admitted", %{
    project: project
  } do
    {_t1, run1} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000
    {t2, run2} = submit(project)
    await_deferred(t2)

    assert %{run_id: ^run2, task_id: ^t2, status: "deferred", reason: "run_limit_exceeded"} =
             ProjectionStore.pending_run(run2)

    # A run that exists is not "pending", and an unknown id is nobody's run.
    assert ProjectionStore.pending_run(run1) == nil
    assert ProjectionStore.pending_run("run-nobody") == nil

    raise_limit!(project, 2)
    assert_receive {:run_supervisor_start, ^run2}, 10_000
    assert ProjectionStore.pending_run(run2) == nil
  end

  test "a deferred task starts when a finished run frees its reservation", %{project: project} do
    {_t1, run1} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000
    {t2, run2} = submit(project)
    await_deferred(t2)

    # What the RunLifecycleReconciler dispatches after a terminal run event.
    release!(project, run1, "terminal_run")
    assert_receive {:run_supervisor_start, ^run2}, 10_000
  end

  test "a reservation released for another reason does not re-admit (no retry loop)", %{
    project: project
  } do
    {_t1, run1} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000
    {t2, run2} = submit(project)
    await_deferred(t2)

    release!(project, run1, "definitive_retry_rejection")
    # The release event was broadcast before the command returned, so it is in
    # the Dispatcher's mailbox ahead of this synchronous call.
    _ = :sys.get_state(ForemanServer.Workflow.Dispatcher)
    refute_received {:run_supervisor_start, ^run2}
    assert %{status: "deferred"} = ProjectionStore.pending_run(run2)
  end

  defp release!(project, run_id, reason) do
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.release_run_reservation",
        aggregate_id: "project:#{project}",
        command_id: "rel-#{System.unique_integer([:positive])}",
        payload: %{project_id: project, run_id: run_id, reason: reason}
      })
  end

  defp raise_limit!(project, n) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "project.update",
        aggregate_id: "project:#{project}",
        command_id: "u-#{System.unique_integer([:positive])}",
        payload: %{project_id: project, max_concurrent_runs: n}
      })
  end
end
