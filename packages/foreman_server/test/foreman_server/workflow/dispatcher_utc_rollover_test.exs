defmodule ForemanServer.Workflow.DispatcherUtcRolloverTest do
  # E1-S4 (foreman-7wsyx): work refused by the daily thread cap is "retried later, after the cap
  # resets". The cap clears at the UTC day boundary and no event announces that, so the Dispatcher
  # arms a timer for the next UTC midnight and re-admits every project's deferred tasks when it
  # fires. The clock is injected (`:now_fun`): nothing here waits for a real midnight.
  #
  # Like `DispatcherProjectResumeTest`, the handler is driven directly with the mocks installed
  # while the app's own Dispatcher is frozen.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.ProjectLimits
  alias ForemanServer.Workflow.Dispatcher

  @day_ms 86_400_000

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)
    {:ok, _} = Application.ensure_all_started(:meck)
    :ok
  end

  setup do
    # See `ForemanServer.DispatcherQuiesce`: the app's Dispatcher would otherwise act on events
    # through the mocked modules below and put messages in this test's mailbox.
    :ok = ForemanServer.DispatcherQuiesce.suspend!()

    :meck.new(ForemanServer.ProjectionStore, [:no_link, :passthrough])
    :meck.new(ForemanServer.RunAdmission, [:no_link])
    :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link])

    # Unconditional: an expectation that raised (the projection-exit test) marks its mock invalid,
    # and an unloaded-only-if-valid mock would make the NEXT test's `:meck.new` fail.
    on_exit(fn ->
      :meck.unload([
        ForemanServer.ProjectionStore,
        ForemanServer.RunAdmission,
        ForemanServer.Workflow.RunSupervisor
      ])
    end)

    # `Dispatcher.crash_resume_opts/2` reads the REAL run projection for these ids, so they must
    # be ones no other test can use (see `DispatcherProjectResumeTest`).
    n = System.unique_integer([:positive])
    {:ok, run1: "run-rollover-#{n}-1", run2: "run-rollover-#{n}-2"}
  end

  defp task(task_id, run_id, project_id) do
    %{
      status: "in_progress",
      task_id: task_id,
      run_id: run_id,
      project_id: project_id,
      approval_id: "approval-#{task_id}",
      workflow_snapshot: %{phases: []}
    }
  end

  defp expect_projection(deferred_by_project, tasks) do
    projects = Enum.map(Map.keys(deferred_by_project), &%{project_id: &1})

    :meck.expect(ForemanServer.ProjectionStore, :list_projects, fn -> projects end)

    :meck.expect(ForemanServer.ProjectionStore, :deferred_task_ids, fn project_id ->
      Map.fetch!(deferred_by_project, project_id)
    end)

    :meck.expect(ForemanServer.ProjectionStore, :task_projection, fn id -> Map.get(tasks, id) end)
  end

  defp state_at(%DateTime{} = now), do: %{now_fun: fn -> now end}

  # The timer the handler re-armed, cancelled so it cannot fire into this test process.
  defp rearmed_in!(%{rollover_timer: ref}) do
    remaining = Process.read_timer(ref)
    Process.cancel_timer(ref)
    assert is_integer(remaining), "the rollover timer was not re-armed"
    remaining
  end

  test "at the UTC rollover every project's deferred tasks re-enter admission and start",
       %{run1: run1, run2: run2} do
    expect_projection(
      %{"proj-a" => ["t1"], "proj-b" => ["t2"]},
      %{"t1" => task("t1", run1, "proj-a"), "t2" => task("t2", run2, "proj-b")}
    )

    test_pid = self()

    :meck.expect(ForemanServer.RunAdmission, :start, fn project_id, payload ->
      send(test_pid, {:admitted, project_id, payload.run_id})
      {:ok, %{event_type: "RunStarted"}}
    end)

    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn run_id, _task, opts ->
      send(test_pid, {:started, run_id, opts})
      {:ok, :child}
    end)

    # Two seconds into the day after the one the timer was armed on.
    state = state_at(~U[2026-10-26 00:00:02Z])

    assert {:noreply, state} = Dispatcher.handle_info({:utc_rollover, "2026-10-25"}, state)

    assert_received {:admitted, "proj-a", ^run1}
    assert_received {:admitted, "proj-b", ^run2}
    # Never started, so started FRESH: a resume would skip phases it never ran.
    assert_received {:started, ^run1, []}
    assert_received {:started, ^run2, []}

    # Next stop is the following midnight: 24 h minus the two seconds already into the day.
    assert rearmed_in!(state) in (@day_ms - 2_000 - 50)..(@day_ms - 2_000)
  end

  test "a task the cap refuses again stays deferred, and the next midnight is still armed",
       %{run1: run1} do
    expect_projection(%{"proj-a" => ["t1"]}, %{"t1" => task("t1", run1, "proj-a")})
    test_pid = self()

    :meck.expect(ForemanServer.RunAdmission, :start, fn _project_id, payload ->
      send(test_pid, {:admitted, payload.run_id})
      {:error, {:daily_thread_cap_exceeded, 1, "2026-10-26"}}
    end)

    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn _, _, _ ->
      flunk("a refused admission must not start the run")
    end)

    state = state_at(~U[2026-10-26 00:00:00Z])

    capture_log(fn ->
      assert {:noreply, state} = Dispatcher.handle_info({:utc_rollover, "2026-10-25"}, state)
      assert_received {:admitted, ^run1}
      assert rearmed_in!(state) in (@day_ms - 50)..@day_ms
    end)
  end

  test "a timer that fires before the clock has moved on re-admits nothing and waits out the rest" do
    :meck.expect(ForemanServer.ProjectionStore, :list_projects, fn ->
      flunk("must not look for deferred tasks while the cap has not reset")
    end)

    :meck.expect(ForemanServer.RunAdmission, :start, fn _, _ -> flunk("must not admit") end)

    # Half a second short of midnight: the clock still reads the day the timer was armed on.
    state = state_at(~U[2026-10-25 23:59:59.500Z])

    assert {:noreply, state} = Dispatcher.handle_info({:utc_rollover, "2026-10-25"}, state)

    assert rearmed_in!(state) in 450..500
    refute :meck.called(ForemanServer.ProjectionStore, :list_projects, [])
  end

  test "a day with nothing deferred admits nothing and still arms the next midnight" do
    expect_projection(%{"proj-a" => []}, %{})
    :meck.expect(ForemanServer.RunAdmission, :start, fn _, _ -> flunk("must not admit") end)

    state = state_at(~U[2026-10-26 00:00:01Z])

    assert {:noreply, state} = Dispatcher.handle_info({:utc_rollover, "2026-10-25"}, state)

    assert :meck.called(ForemanServer.ProjectionStore, :deferred_task_ids, ["proj-a"])
    assert rearmed_in!(state) in (@day_ms - 1_000 - 50)..(@day_ms - 1_000)
  end

  test "a projection that is mid-restart is logged, not raised, and the timer is still re-armed" do
    :meck.expect(ForemanServer.ProjectionStore, :list_projects, fn -> exit(:noproc) end)
    state = state_at(~U[2026-10-26 00:00:00Z])

    log =
      capture_log(fn ->
        assert {:noreply, state} = Dispatcher.handle_info({:utc_rollover, "2026-10-25"}, state)
        assert rearmed_in!(state) in (@day_ms - 50)..@day_ms
      end)

    assert log =~ "UTC rollover re-admission exited"
  end

  test "re-arming replaces the pending timer instead of starting a second chain" do
    :meck.expect(ForemanServer.ProjectionStore, :list_projects, fn -> [] end)

    first = state_at(~U[2026-10-26 00:00:00Z])
    assert {:noreply, first} = Dispatcher.handle_info({:utc_rollover, "2026-10-25"}, first)
    pending = first.rollover_timer

    assert {:noreply, second} = Dispatcher.handle_info({:utc_rollover, "2026-10-25"}, first)

    assert Process.read_timer(pending) == false
    assert is_integer(Process.read_timer(second.rollover_timer))
    Process.cancel_timer(second.rollover_timer)
  end

  test "the app's Dispatcher is armed for the next UTC midnight from boot" do
    %{rollover_timer: ref} = :sys.get_state(Dispatcher)

    # The timer counts down on the monotonic clock, the bound is read off the system clock; they
    # drift apart by a few ms over the minutes since the Dispatcher booted, so the check is
    # "armed for about the next midnight" (within a second), not to the millisecond.
    now = DateTime.utc_now()
    until_midnight = DateTime.diff(ProjectLimits.resets_at(now), now, :millisecond)
    remaining = Process.read_timer(ref)

    assert is_integer(remaining), "the Dispatcher has no pending rollover timer"
    assert remaining in 1..(until_midnight + 1_000)
  end

  test "ProjectLimits.resets_at/1 is the next UTC midnight, and the day it opens is the next day" do
    now = ~U[2026-12-31 23:59:59.999Z]

    assert ProjectLimits.resets_at(now) == ~U[2027-01-01 00:00:00Z]
    assert ProjectLimits.day(ProjectLimits.resets_at(now)) == "2027-01-01"
    # Exactly at midnight the day has already changed, so the NEXT reset is a whole day away.
    assert ProjectLimits.resets_at(~U[2027-01-01 00:00:00Z]) == ~U[2027-01-02 00:00:00Z]
  end
end
