defmodule ForemanServer.Workflow.DispatcherSlotRebalanceTest do
  # TRD-007: the Dispatcher resolves a run's REAL project for slot release,
  # handles promotion events on the project stream, and rebalances a project's
  # queue when its limit changes (`ProjectUpdated`) or it is reactivated.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.RunSlotsReset
  alias ForemanServer.Workflow.Dispatcher

  setup do
    ForemanServer.TestSupport.DispatcherRestart.restart!()
    RunSlotsReset.reset!()

    :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link])
    test = self()

    # Fresh starts only: a duplicate promotion of a run already started resumes
    # it (`resume_from`), which the real supervisor refuses.
    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn run_id, _task, opts ->
      if opts == [], do: send(test, {:run_supervisor_start, run_id})
      {:ok, :child}
    end)

    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn run_id, _task ->
      send(test, {:run_supervisor_start, run_id})
      {:ok, :child}
    end)

    on_exit(fn ->
      if :meck.validate(ForemanServer.Workflow.RunSupervisor),
        do: :meck.unload(ForemanServer.Workflow.RunSupervisor)
    end)

    H.subscribe!()
    :ok
  end

  defp project(limit) do
    id = H.register_project(System.tmp_dir!(), config: %{})
    update!(id, %{max_concurrent_runs: limit})
    id
  end

  defp update!(project, settings) do
    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "project.update",
        aggregate_id: "project:#{project}",
        command_id: "u-#{System.unique_integer([:positive])}",
        payload: Map.merge(%{project_id: project}, settings)
      })
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

    run_id
  end

  defp slot_state(project) do
    {state, _version} = Aggregate.load(RunSlots, RunSlots.stream_id(project))
    state
  end

  defp waiters(project), do: Enum.map(slot_state(project).waiters, & &1.run_id)
  defp holders(project), do: slot_state(project).holders |> Map.keys() |> Enum.sort()

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not reached")
      true -> Process.sleep(50) && eventually(fun, tries - 1)
    end
  end

  describe "rebalance on ProjectUpdated" do
    test "a raised limit starts waiting runs up to the new limit, FIFO" do
      p = project(1)
      r1 = submit(p)
      assert_receive {:run_supervisor_start, ^r1}, 10_000
      [r2, r3, r4] = for _ <- 1..3, do: submit(p)
      eventually(fn -> waiters(p) == [r2, r3, r4] end)

      update!(p, %{max_concurrent_runs: 3})

      assert_receive {:run_supervisor_start, ^r2}, 10_000
      assert_receive {:run_supervisor_start, ^r3}, 10_000
      refute_receive {:run_supervisor_start, ^r4}, 300
      assert waiters(p) == [r4]
      assert holders(p) == Enum.sort([r1, r2, r3])
    end

    test "rebalance of one project does not touch another project's queue" do
      a = project(1)
      b = project(1)
      a1 = submit(a)
      b1 = submit(b)
      assert_receive {:run_supervisor_start, ^a1}, 10_000
      assert_receive {:run_supervisor_start, ^b1}, 10_000
      a2 = submit(a)
      b2 = submit(b)
      eventually(fn -> waiters(a) == [a2] and waiters(b) == [b2] end)

      update!(a, %{max_concurrent_runs: 2})

      assert_receive {:run_supervisor_start, ^a2}, 10_000
      refute_receive {:run_supervisor_start, ^b2}, 300
      assert waiters(b) == [b2]
    end

    test "a limit that does not free capacity starts nothing" do
      p = project(1)
      r1 = submit(p)
      assert_receive {:run_supervisor_start, ^r1}, 10_000
      r2 = submit(p)
      eventually(fn -> waiters(p) == [r2] end)

      update!(p, %{goal: "unrelated setting change"})

      refute_receive {:run_supervisor_start, ^r2}, 300
      assert waiters(p) == [r2]
    end

    test "an empty queue is a no-op and the dispatcher keeps running" do
      p = project(2)
      pid = Process.whereis(Dispatcher)
      update!(p, %{max_concurrent_runs: 4})
      _ = :sys.get_state(Dispatcher)
      assert Process.whereis(Dispatcher) == pid
      assert waiters(p) == []
    end
  end

  describe "rebalance on ProjectReactivated" do
    test "a reactivated project's held queue is rebalanced and its waiter starts" do
      p = project(1)
      r1 = submit(p)
      assert_receive {:run_supervisor_start, ^r1}, 10_000
      r2 = submit(p)
      eventually(fn -> waiters(p) == [r2] end)

      # Free r1's slot with a capacity of 0 so the queue is HELD with no holder
      # (what a limit lowered under the running count leaves behind).
      {:ok, _} =
        CommandGateway.dispatch_system(%{
          type: "run_slots.release",
          command_id: "rel-#{System.unique_integer([:positive])}",
          aggregate_id: RunSlots.stream_id(p),
          payload: %{run_id: r1, project_id: p, capacity: 0, reason: "test"}
        })

      assert holders(p) == []
      assert waiters(p) == [r2]
      refute_received {:run_supervisor_start, ^r2}

      send(
        Dispatcher,
        {:projection_event, %{event_type: "ProjectReactivated", data: %{project_id: p}}}
      )

      assert_receive {:run_supervisor_start, ^r2}, 10_000
      assert holders(p) == [r2]
      assert waiters(p) == []
    end
  end

  describe "slot release targets the run's own project" do
    setup do
      :ok = ForemanServer.DispatcherQuiesce.suspend!()
      {:ok, _} = Application.ensure_all_started(:meck)
      :meck.new(ForemanServer.CommandGateway, [:passthrough, :no_link])
      test = self()

      :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command ->
        send(test, {:dispatch_system, command})
        :meck.passthrough([command])
      end)

      :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command, timeout ->
        send(test, {:dispatch_system, command})
        :meck.passthrough([command, timeout])
      end)

      on_exit(fn ->
        if :meck.validate(ForemanServer.CommandGateway),
          do: :meck.unload(ForemanServer.CommandGateway)
      end)

      :ok
    end

    for event <-
          ~w(RunCompleted RunFailed RunCancelled RunFlaggedStuck RunBlocked RunDeleted RunPaused) do
      test "#{event} releases only its project's stream" do
        run_a = "run-a-#{System.unique_integer([:positive])}"
        run_b = "run-b-#{System.unique_integer([:positive])}"
        :meck.new(ProjectionStore, [:passthrough, :no_link])

        :meck.expect(ProjectionStore, :run, fn
          ^run_a -> %{run_id: run_a, project_id: "proj-a", status: "paused"}
          ^run_b -> %{run_id: run_b, project_id: "proj-b", status: "paused"}
          _ -> nil
        end)

        on_exit(fn -> if :meck.validate(ProjectionStore), do: :meck.unload(ProjectionStore) end)

        for run <- [run_a, run_b] do
          {:noreply, _} =
            Dispatcher.handle_info(
              {:projection_event, %{event_type: unquote(event), data: %{run_id: run}}},
              %{}
            )
        end

        assert_receive {:dispatch_system,
                        %{type: "run_slots.release", aggregate_id: "run_slots:proj-a"} = ca},
                       2_000

        assert ca.payload.run_id == run_a
        assert ca.payload.project_id == "proj-a"

        assert_receive {:dispatch_system,
                        %{type: "run_slots.release", aggregate_id: "run_slots:proj-b"} = cb},
                       2_000

        assert cb.payload.run_id == run_b

        # A queued (waiter) run that ends is dropped from its own project's queue too.
        assert_receive {:dispatch_system,
                        %{type: "run_slots.remove_waiter", aggregate_id: "run_slots:proj-a"} = ra},
                       2_000

        assert ra.payload.run_id == run_a
        refute_received {:dispatch_system, %{aggregate_id: "run_slots:global"}}
      end
    end

    test "the task projection is the fallback when the run projection is gone" do
      run = "run-task-fallback-#{System.unique_integer([:positive])}"
      :meck.new(ProjectionStore, [:passthrough, :no_link])
      :meck.expect(ProjectionStore, :run, fn _ -> nil end)
      :meck.expect(ProjectionStore, :tasks_by_run_id, fn ^run -> [%{project_id: "proj-t"}] end)
      on_exit(fn -> if :meck.validate(ProjectionStore), do: :meck.unload(ProjectionStore) end)

      {:noreply, _} =
        Dispatcher.handle_info(
          {:projection_event, %{event_type: "RunDeleted", data: %{run_id: run}}},
          %{}
        )

      assert_receive {:dispatch_system,
                      %{type: "run_slots.release", aggregate_id: "run_slots:proj-t"}},
                     2_000
    end

    test "an unresolvable project logs a warning naming the run and dispatches nothing" do
      run = "run-orphan-#{System.unique_integer([:positive])}"
      :meck.new(ProjectionStore, [:passthrough, :no_link])
      :meck.expect(ProjectionStore, :run, fn _ -> nil end)
      :meck.expect(ProjectionStore, :tasks_by_run_id, fn _ -> [] end)
      on_exit(fn -> if :meck.validate(ProjectionStore), do: :meck.unload(ProjectionStore) end)

      log =
        capture_log([level: :warning], fn ->
          {:noreply, _} =
            Dispatcher.handle_info(
              {:projection_event, %{event_type: "RunCompleted", data: %{run_id: run}}},
              %{}
            )
        end)

      assert log =~ run
      refute_received {:dispatch_system, %{type: "run_slots.release"}}

      # Later events are still handled.
      {:noreply, _} =
        Dispatcher.handle_info(
          {:projection_event, %{event_type: "RunCompleted", data: %{run_id: run}}},
          %{}
        )
    end
  end

  describe "promotion events" do
    setup do
      :ok = ForemanServer.DispatcherQuiesce.suspend!()
      :meck.new(ForemanServer.RunAdmission, [:no_link])
      test = self()

      :meck.expect(ForemanServer.RunAdmission, :start, fn project_id, payload ->
        send(test, {:admission_start, project_id, payload.run_id})
        {:ok, :slot_queued}
      end)

      on_exit(fn ->
        if :meck.validate(ForemanServer.RunAdmission),
          do: :meck.unload(ForemanServer.RunAdmission)
      end)

      :ok
    end

    defp with_task(run, project) do
      :meck.new(ProjectionStore, [:passthrough, :no_link])
      :meck.expect(ProjectionStore, :run, fn _ -> nil end)

      :meck.expect(ProjectionStore, :tasks_by_run_id, fn ^run ->
        [%{task_id: "t-#{run}", project_id: project, workflow_snapshot: %{}}]
      end)

      on_exit(fn -> if :meck.validate(ProjectionStore), do: :meck.unload(ProjectionStore) end)
    end

    test "RunSlotAcquired with promoted: true re-enters admission (struct payload)" do
      run = "run-promoted-acq-#{System.unique_integer([:positive])}"
      with_task(run, "proj-x")

      data = %ForemanServer.Events.RunSlotAcquired{
        run_id: run,
        capacity: 1,
        acquired_at_ms: 1,
        project_id: "proj-x",
        promoted: true
      }

      {:noreply, _} =
        Dispatcher.handle_info(
          {:projection_event, %{event_type: "RunSlotAcquired", data: data}},
          %{}
        )

      assert_receive {:admission_start, "proj-x", ^run}, 2_000
    end

    test "an ordinary RunSlotAcquired (not promoted) does nothing" do
      run = "run-plain-acq-#{System.unique_integer([:positive])}"
      with_task(run, "proj-x")

      data = %ForemanServer.Events.RunSlotAcquired{
        run_id: run,
        capacity: 1,
        acquired_at_ms: 1,
        project_id: "proj-x"
      }

      {:noreply, _} =
        Dispatcher.handle_info(
          {:projection_event, %{event_type: "RunSlotAcquired", data: data}},
          %{}
        )

      refute_receive {:admission_start, _, ^run}, 200
    end

    test "RunSlotTransferred as a struct payload re-enters admission" do
      run = "run-promoted-xfer-#{System.unique_integer([:positive])}"
      with_task(run, "proj-x")

      data = %ForemanServer.Events.RunSlotTransferred{
        released_run_id: "run-old",
        acquired_run_id: run,
        capacity: 1,
        acquired_at_ms: 1,
        project_id: "proj-x"
      }

      {:noreply, _} =
        Dispatcher.handle_info(
          {:projection_event, %{event_type: "RunSlotTransferred", data: data}},
          %{}
        )

      assert_receive {:admission_start, "proj-x", ^run}, 2_000
    end

    test "a promoted run that is already terminal is not started and its slot is released" do
      run = "run-promoted-dead-#{System.unique_integer([:positive])}"
      with_task(run, "proj-x")
      test = self()

      :meck.expect(ProjectionStore, :run, fn ^run ->
        %{run_id: run, terminal?: true, status: "cancelled", project_id: "proj-x"}
      end)

      :meck.new(ForemanServer.CommandGateway, [:passthrough, :no_link])

      :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command ->
        send(test, {:dispatch_system, command})
        {:ok, nil}
      end)

      on_exit(fn ->
        if :meck.validate(ForemanServer.CommandGateway),
          do: :meck.unload(ForemanServer.CommandGateway)
      end)

      {:noreply, _} =
        Dispatcher.handle_info(
          {:projection_event,
           %{
             event_type: "RunSlotTransferred",
             data: %{acquired_run_id: run, released_run_id: "x"}
           }},
          %{}
        )

      refute_receive {:admission_start, _, ^run}, 200

      assert_receive {:dispatch_system,
                      %{type: "run_slots.release", aggregate_id: "run_slots:proj-x"}},
                     2_000
    end
  end

  describe "resume with an unresolvable project" do
    test "RunAdmission.resume returning missing project_id logs a warning naming the run" do
      :ok = ForemanServer.DispatcherQuiesce.suspend!()
      run = "run-resume-noproj-#{System.unique_integer([:positive])}"
      :meck.new(ForemanServer.RunAdmission, [:no_link])

      :meck.expect(ForemanServer.RunAdmission, :resume, fn _ ->
        {:error, {:missing_or_invalid, :project_id, nil}}
      end)

      :meck.new(ProjectionStore, [:passthrough, :no_link])

      :meck.expect(ProjectionStore, :tasks_by_run_id, fn ^run ->
        [%{task_id: "t", project_id: nil, workflow_snapshot: %{}}]
      end)

      on_exit(fn ->
        for m <- [ForemanServer.RunAdmission, ProjectionStore],
            do: if(:meck.validate(m), do: :meck.unload(m))
      end)

      log =
        capture_log([level: :warning], fn ->
          {:noreply, _} =
            Dispatcher.handle_info(
              {:projection_event, %{event_type: "RunResumed", data: %{run_id: run}}},
              %{}
            )
        end)

      assert log =~ run
      refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
    end
  end
end
