defmodule ForemanServer.Workflow.DispatcherRunLimitReadmissionTest do
  # Per-project dispatch queues (TRD-007): with `max_concurrent_runs: 1` the second
  # submitted task is NOT deferred. It queues FIFO in its project's own
  # `run_slots:<project_id>` stream and starts when the running run releases its
  # slot, when the limit is raised, or never if it is cancelled/removed first.
  # Exercised against the real Dispatcher, RunAdmission and projection.
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.RunSlotsReset

  setup do
    # Other files may have left the app-level Dispatcher stopped, suspended or
    # unsubscribed; this test needs the real, subscribed one.
    ForemanServer.TestSupport.DispatcherRestart.restart!()

    # Other files leave holders in the slot aggregates; a full slot would queue
    # the first run instead of admitting it.
    RunSlotsReset.reset!()

    :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link])
    test = self()

    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn run_id, _task, opts ->
      # A queued run was never started, so promotion must start it FRESH
      # (no `resume_from`); a resume here would skip phases it never ran.
      [] = opts
      send(test, {:run_supervisor_start, run_id})
      {:ok, :child}
    end)

    on_exit(fn ->
      if :meck.validate(ForemanServer.Workflow.RunSupervisor),
        do: :meck.unload(ForemanServer.Workflow.RunSupervisor)
    end)

    H.subscribe!()
    project = new_project(1)

    {:ok, project: project}
  end

  defp new_project(limit) do
    project = H.register_project(System.tmp_dir!(), config: %{})
    raise_limit!(project, limit)
    project
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

  # The run ids waiting in `project`'s own slot stream, in queue order.
  defp waiters(project) do
    {state, _version} = Aggregate.load(RunSlots, RunSlots.stream_id(project))
    Enum.map(state.waiters, & &1.run_id)
  end

  defp await_waiters(project, expected, tries \\ 100) do
    cond do
      waiters(project) == expected ->
        :ok

      tries == 0 ->
        flunk("waiters of #{project} are #{inspect(waiters(project))}, want #{inspect(expected)}")

      true ->
        Process.sleep(50)
        await_waiters(project, expected, tries - 1)
    end
  end

  defp cancel!(run_id) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "run.cancel",
        aggregate_id: "run:#{run_id}",
        command_id: "cancel-#{System.unique_integer([:positive])}",
        payload: %{run_id: run_id}
      })
  end

  defp remove_waiter!(project, run_id) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run_slots.remove_waiter",
        command_id: "rw-#{System.unique_integer([:positive])}",
        aggregate_id: RunSlots.stream_id(project),
        payload: %{run_id: run_id, project_id: project}
      })
  end

  test "an over-limit run queues in its project's stream and starts when the limit is raised",
       %{project: project} do
    {_t1, run1} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000

    {_t2, run2} = submit(project)
    await_waiters(project, [run2])
    refute_received {:run_supervisor_start, ^run2}

    raise_limit!(project, 2)

    assert_receive {:run_supervisor_start, ^run2}, 10_000
    await_waiters(project, [])
  end

  test "a raised setting starts up to the added waiters, in order, without operator action" do
    project = new_project(3)
    running = for _ <- 1..3, do: submit(project)

    for {_t, run} <- running, do: assert_receive({:run_supervisor_start, ^run}, 10_000)

    waiting = for _ <- 1..3, do: submit(project)
    ids = Enum.map(waiting, &elem(&1, 1))
    await_waiters(project, ids)

    raise_limit!(project, 5)

    [w1, w2, w3] = ids
    assert_receive {:run_supervisor_start, ^w1}, 10_000
    assert_receive {:run_supervisor_start, ^w2}, 10_000
    refute_receive {:run_supervisor_start, ^w3}, 300
    await_waiters(project, [w3])
  end

  test "a queued run is queued (not 404) until it is admitted", %{project: project} do
    {_t1, run1} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000
    {t2, run2} = submit(project)
    await_waiters(project, [run2])

    assert %{run_id: ^run2, task_id: ^t2, status: "queued", reason: nil} =
             ProjectionStore.pending_run(run2)

    # A run that exists is not "pending", and an unknown id is nobody's run.
    assert ProjectionStore.pending_run(run1) == nil
    assert ProjectionStore.pending_run("run-nobody") == nil

    raise_limit!(project, 2)
    assert_receive {:run_supervisor_start, ^run2}, 10_000
    assert ProjectionStore.pending_run(run2) == nil
  end

  test "a finished run frees its slot and the project's waiter starts", %{project: project} do
    {_t1, run1} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000
    {_t2, run2} = submit(project)
    await_waiters(project, [run2])

    # The Dispatcher resolves run1's project from its run projection and
    # releases on that project's stream.
    cancel!(run1)
    assert_receive {:run_supervisor_start, ^run2}, 10_000
  end

  test "a freed slot goes to the same project's waiter only", %{project: a} do
    b = new_project(1)

    {_ta1, a1} = submit(a)
    {_tb1, b1} = submit(b)
    assert_receive {:run_supervisor_start, ^a1}, 10_000
    assert_receive {:run_supervisor_start, ^b1}, 10_000

    {_ta2, a2} = submit(a)
    {_tb2, b2} = submit(b)
    await_waiters(a, [a2])
    await_waiters(b, [b2])

    cancel!(a1)

    assert_receive {:run_supervisor_start, ^a2}, 10_000
    refute_receive {:run_supervisor_start, ^b2}, 500
    await_waiters(b, [b2])
  end

  test "a removed waiter is skipped and the others start in order", %{project: project} do
    {_t1, run1} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000

    [{_, x}, {_, y}, {_, z}] = for _ <- 1..3, do: submit(project)
    await_waiters(project, [x, y, z])

    remove_waiter!(project, y)
    await_waiters(project, [x, z])

    cancel!(run1)
    assert_receive {:run_supervisor_start, ^x}, 10_000

    cancel!(x)
    assert_receive {:run_supervisor_start, ^z}, 10_000
    refute_received {:run_supervisor_start, ^y}
  end

  test "a PR-fix style run is its own run and queues for its own slot", %{project: project} do
    {_t1, run1} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000

    # A second run of the same project (what a fix thread on run1's PR is) takes
    # its own slot: it queues because the project is full.
    {_t2, fix_run} = submit(project)
    await_waiters(project, [fix_run])
    refute_received {:run_supervisor_start, ^fix_run}
  end

  test "a queued run on a limit lowered below the running count waits for releases",
       %{project: project} do
    raise_limit!(project, 2)
    {_t1, run1} = submit(project)
    {_t2, run2} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000
    assert_receive {:run_supervisor_start, ^run2}, 10_000

    {_t3, run3} = submit(project)
    await_waiters(project, [run3])
    raise_limit!(project, 1)

    cancel!(run1)
    refute_receive {:run_supervisor_start, ^run3}, 500
    cancel!(run2)
    assert_receive {:run_supervisor_start, ^run3}, 10_000
  end

  test "a task deferred by the daily cap re-enters its project's queue when the cap is raised",
       %{project: project} do
    update_project!(project, %{daily_thread_cap: 1})
    {_t1, run1} = submit(project)
    assert_receive {:run_supervisor_start, ^run1}, 10_000

    {t2, run2} = submit(project)
    await_deferred(t2)
    assert %{status: "deferred"} = ProjectionStore.pending_run(run2)

    update_project!(project, %{daily_thread_cap: 5})

    # Admitted again, and because the project is full (limit 1) into ITS queue.
    await_waiters(project, [run2])
    refute_received {:run_supervisor_start, ^run2}
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

  defp update_project!(project, settings) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "project.update",
        aggregate_id: "project:#{project}",
        command_id: "u-#{System.unique_integer([:positive])}",
        payload: Map.merge(%{project_id: project}, settings)
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
