defmodule ForemanServer.Workflow.DispatcherAdoptionRequeueTest do
  # TRD-017-TEST (AC-017-3): a waiting run follows its thread when the thread is adopted
  # by another project. The Dispatcher handles `ProjectSubjectAdopted` (mode "move"): the
  # run leaves the source project's queue and joins the BACK of the destination's.
  #
  # Step 1 records, through the real `CommandGateway`, whether the Project aggregate
  # accepts adopting a thread whose run is queued. The assertion states the real outcome
  # (it is a fact now, not an assumption): a queued run is a NON-TERMINAL run, so
  # `Projects.Adoption` reports the subject active and the aggregate refuses with
  # `{:subject_active, status}`. Consequently AC-017-3 is unreachable through the real
  # command path today (TRD Known Gaps); the handler is therefore exercised by delivering
  # the `ProjectSubjectAdopted` event it would receive, to the Dispatcher directly.
  use ExUnit.Case, async: false

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

    {:ok, _} =
      CommandGateway.dispatch_operator(%{
        type: "project.update",
        aggregate_id: "project:#{id}",
        command_id: "u-#{System.unique_integer([:positive])}",
        payload: %{project_id: id, max_concurrent_runs: limit}
      })

    id
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

  # Source A (limit `a_limit`): one holder + `n` waiters. Destination B (limit `b_limit`):
  # one holder + `b_waiters` waiters.
  defp seed(opts \\ []) do
    n = Keyword.get(opts, :source_waiters, 1)
    b_limit = Keyword.get(opts, :b_limit, 1)
    b_waiters = Keyword.get(opts, :b_waiters, 2)

    a = project(1)
    b = project(b_limit)

    {_, a_holder} = submit(a)
    {_, b_holder} = submit(b)
    assert_receive {:run_supervisor_start, ^a_holder}, 10_000
    assert_receive {:run_supervisor_start, ^b_holder}, 10_000

    a_subjects = for _ <- 1..n, do: submit(a)
    b_runs = for _ <- 1..b_waiters//1, do: elem(submit(b), 1)
    a_waiters = Enum.map(a_subjects, &elem(&1, 1))
    eventually(fn -> waiters(a) == a_waiters and waiters(b) == b_runs end)

    %{
      a: a,
      b: b,
      a_holder: a_holder,
      a_task: a_subjects |> hd() |> elem(0),
      a_waiters: a_waiters,
      b_waiters: b_runs
    }
  end

  defp adopted_event(ctx, moved_run_ids, extra \\ %{}) do
    data =
      Map.merge(
        %{
          project_id: ctx.b,
          subject_kind: "task",
          subject_id: ctx.a_task,
          mode: "move",
          from_project_id: ctx.a,
          moved: %{task_ids: [ctx.a_task], run_ids: moved_run_ids, jobsite_ids: []},
          adopted_at: "2026-11-20T00:00:00Z"
        },
        extra
      )

    %{
      event_type: "ProjectSubjectAdopted",
      event_id: "evt-#{System.unique_integer([:positive])}",
      data: data
    }
  end

  defp capture_slot_commands do
    {:ok, _} = Application.ensure_all_started(:meck)
    :meck.new(ForemanServer.CommandGateway, [:passthrough, :no_link])
    test = self()

    :meck.expect(ForemanServer.CommandGateway, :dispatch_system, fn command ->
      if String.starts_with?(command.type, "run_slots."),
        do: send(test, {:slot_command, command})

      :meck.passthrough([command])
    end)

    on_exit(fn ->
      if :meck.validate(ForemanServer.CommandGateway),
        do: :meck.unload(ForemanServer.CommandGateway)
    end)
  end

  defp drain_slot_commands(acc \\ []) do
    receive do
      {:slot_command, command} -> drain_slot_commands([command | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  describe "the real adoption path (recorded outcome)" do
    test "the aggregate refuses to adopt a thread whose run is queued; both queues are untouched" do
      ctx = seed()
      [a_waiter] = ctx.a_waiters

      # The recorded fact: a queued run is non-terminal, hence active, hence refused.
      assert {:error, {:subject_active, status}} =
               CommandGateway.dispatch_operator(%{
                 type: "project.adopt",
                 command_id: "adopt-#{System.unique_integer([:positive])}",
                 aggregate_id: "project:#{ctx.b}",
                 payload: %{
                   project_id: ctx.b,
                   subject_kind: "task",
                   subject_id: ctx.a_task,
                   mode: "move"
                 }
               })

      assert is_binary(status)

      # No ProjectSubjectAdopted was emitted, so the Dispatcher handler never ran.
      _ = :sys.get_state(Dispatcher)
      assert waiters(ctx.a) == [a_waiter]
      assert holders(ctx.a) == [ctx.a_holder]
      assert waiters(ctx.b) == ctx.b_waiters
    end
  end

  describe "ProjectSubjectAdopted (move) handled by the Dispatcher" do
    test "a moved waiter queues third in the destination and leaves the source" do
      ctx = seed()
      [a_waiter] = ctx.a_waiters

      send(Dispatcher, {:projection_event, adopted_event(ctx, [a_waiter])})

      eventually(fn ->
        waiters(ctx.b) == ctx.b_waiters ++ [a_waiter] and waiters(ctx.a) == []
      end)

      assert waiters(ctx.a) == []
      assert holders(ctx.a) == [ctx.a_holder]
      refute_receive {:run_supervisor_start, ^a_waiter}, 300
    end

    test "several moved waiters keep their relative (source queue) order" do
      ctx = seed(source_waiters: 3)
      [w1, w2, w3] = ctx.a_waiters

      # Event lists them out of order; the source queue decides.
      send(Dispatcher, {:projection_event, adopted_event(ctx, [w3, w1, w2])})

      eventually(fn ->
        waiters(ctx.b) == ctx.b_waiters ++ [w1, w2, w3] and waiters(ctx.a) == []
      end)

      assert waiters(ctx.a) == []
    end

    test "a moved task's waiting run is found through moved.task_ids" do
      ctx = seed()
      [a_waiter] = ctx.a_waiters

      send(Dispatcher, {:projection_event, adopted_event(ctx, [])})

      eventually(fn ->
        waiters(ctx.b) == ctx.b_waiters ++ [a_waiter] and waiters(ctx.a) == []
      end)

      assert waiters(ctx.a) == []
    end

    test "an adopted run that is not a waiter dispatches no slot command" do
      ctx = seed()
      capture_slot_commands()

      # The holder is running (not a waiter); an unknown id is neither.
      send(
        Dispatcher,
        {:projection_event,
         adopted_event(ctx, [ctx.a_holder, "run-unknown"], %{
           moved: %{task_ids: [], run_ids: [ctx.a_holder, "run-unknown"], jobsite_ids: []}
         })}
      )

      assert [] = drain_slot_commands() |> Enum.reject(&(&1.type == "run_slots.promote"))
      assert holders(ctx.a) == [ctx.a_holder]
      assert waiters(ctx.b) == ctx.b_waiters
    end

    test "mode continue moves nothing" do
      ctx = seed()
      [a_waiter] = ctx.a_waiters

      send(
        Dispatcher,
        {:projection_event,
         adopted_event(ctx, [a_waiter], %{mode: "continue", new_task_id: "task-new"})}
      )

      _ = :sys.get_state(Dispatcher)
      refute_receive {:run_supervisor_start, _}, 300
      assert waiters(ctx.a) == [a_waiter]
      assert waiters(ctx.b) == ctx.b_waiters
    end

    test "a redelivered event leaves the destination queue unchanged" do
      ctx = seed()
      [a_waiter] = ctx.a_waiters
      event = adopted_event(ctx, [a_waiter])

      send(Dispatcher, {:projection_event, event})

      eventually(fn ->
        waiters(ctx.b) == ctx.b_waiters ++ [a_waiter] and waiters(ctx.a) == []
      end)

      send(Dispatcher, {:projection_event, event})
      _ = :sys.get_state(Dispatcher)
      Process.sleep(200)
      assert waiters(ctx.b) == ctx.b_waiters ++ [a_waiter]
    end

    test "the destination is rebalanced: a moved waiter starts when the destination has room" do
      ctx = seed(b_limit: 2, b_waiters: 0)
      [a_waiter] = ctx.a_waiters

      # Fold the adoption into the read side too, as the real event would (the run's task
      # now belongs to B), then hand the event to the Dispatcher.
      event = adopted_event(ctx, [a_waiter])

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "ProjectSubjectAdopted", payload: event.data}
        ])

      send(Dispatcher, {:projection_event, event})

      assert_receive {:run_supervisor_start, ^a_waiter}, 10_000
      assert waiters(ctx.b) == []
      assert a_waiter in holders(ctx.b)
      assert waiters(ctx.a) == []
    end
  end
end
