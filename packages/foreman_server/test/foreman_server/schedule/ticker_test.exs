defmodule ForemanServer.Schedule.TickerTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore, Recovery}
  alias ForemanServer.Schedule.Ticker
  alias ForemanServer.TestSupport.ProjectionStoreReset

  defmodule FaultDispatch do
    @moduledoc false
    # Delegates to the real gateway except for commands the test scripted to fail.
    # Faults live in :persistent_term so the ticker's task processes can read them.
    def put(faults), do: :persistent_term.put({__MODULE__, :faults}, faults)
    def clear, do: :persistent_term.erase({__MODULE__, :faults})

    def dispatch_system(command) do
      case fault(command) do
        nil -> CommandGateway.dispatch_system(command)
        {:raise, message} -> raise message
        result -> result
      end
    end

    def dispatch_system_approval(command), do: CommandGateway.dispatch_system_approval(command)

    defp fault(command) do
      faults = :persistent_term.get({__MODULE__, :faults}, [])

      Enum.find_value(faults, fn {type, schedule_fragment, result} ->
        if command.type == type and String.contains?(command.command_id, schedule_fragment),
          do: result
      end)
    end
  end

  setup do
    ProjectionStoreReset.reset!()

    on_exit(fn ->
      FaultDispatch.clear()
      ProjectionStoreReset.reset!()
    end)

    project_id = "tk-#{Elixir.EventStore.UUID.uuid4()}"
    register_project(project_id)
    {:ok, clock} = start_supervised({Agent, fn -> DateTime.utc_now() end})
    {:ok, p: project_id, clock: clock}
  end

  defp register_project(project_id, config \\ %{}) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRegistered",
          payload: %{project_id: project_id, path: "/tmp/#{project_id}", config: config}
        }
      ])
  end

  defp start_ticker(ctx, opts \\ []) do
    clock = ctx.clock
    base = [interval_ms: 0, now_fun: fn -> Agent.get(clock, & &1) end, recovery_grace_ms: 0]
    start_supervised!({Ticker, Keyword.merge(base, opts)})
  end

  defp restart_ticker(ctx, opts \\ []) do
    :ok = stop_supervised(Ticker)
    start_ticker(ctx, opts)
  end

  defp set_clock(ctx, unix), do: Agent.update(ctx.clock, fn _ -> DateTime.from_unix!(unix) end)

  # Creates a schedule through the real operator path. Interval specs are
  # epoch-hour aligned so slots are whole hours.
  defp create_schedule(ctx, overrides \\ %{}) do
    id = "s-#{System.unique_integer([:positive])}"
    project_id = Map.get(overrides, :project_id, ctx.p)

    payload =
      Map.merge(
        %{
          project_id: project_id,
          schedule_id: id,
          name: "hourly #{id}",
          spec: %{"every" => "1h", "anchor" => "2026-01-01T00:00:00Z"},
          prompt: "do the thing",
          workflow: "implement",
          auto_approve: false,
          overlap: "skip"
        },
        overrides
      )

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "create-#{id}",
               type: "schedule.create",
               aggregate_id: "schedule:#{project_id}:#{id}",
               payload: payload
             })

    id
  end

  # First whole-hour slot after the schedule's baseline (creation instant).
  defp first_slot(ctx, id, project_id \\ nil) do
    schedule = ProjectionStore.schedule(project_id || ctx.p, id)
    (div(schedule.active_since, 3_600) + 1) * 3_600
  end

  defp operator(ctx, type, id, extra \\ %{}) do
    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "#{type}-#{id}-#{System.unique_integer([:positive])}",
               type: type,
               aggregate_id: "schedule:#{ctx.p}:#{id}",
               payload: Map.merge(%{project_id: ctx.p, schedule_id: id}, extra)
             })
  end

  defp task_id(id, slot), do: "sched-#{id}-#{slot}"

  defp schedule(ctx, id), do: ProjectionStore.schedule(ctx.p, id)

  defp intent(intent_id),
    do: Enum.find(ProjectionStore.list_scheduler_intents(), &(&1.intent_id == intent_id))

  defp stream_types(stream) do
    {:ok, events} = EventStore.read_stream_forward(stream, 0, 99_999)
    Enum.map(events, & &1.event_type)
  end

  # (1) ---------------------------------------------------------------------

  test "a due slot creates exactly one task; a second tick at the same instant adds nothing",
       ctx do
    id = create_schedule(ctx)
    slot = first_slot(ctx, id)
    set_clock(ctx, slot + 5)
    start_ticker(ctx)

    :ok = Ticker.tick_now()

    assert %{status: "open", project_id: p, prompt: "do the thing", provider_tracked: false} =
             ProjectionStore.task_projection(task_id(id, slot))

    assert p == ctx.p

    assert %{last_slot: ^slot, last_outcome: %{kind: "fired", slot: ^slot}, last_task_id: tid} =
             schedule(ctx, id)

    assert tid == task_id(id, slot)
    assert %{status: "confirmed", slot: ^slot} = intent("#{id}:#{slot}")
    assert %{fired: 1, skipped: 0, errors: 0} = Ticker.stats()

    :ok = Ticker.tick_now()

    assert %{fired: 1, errors: 0} = Ticker.stats()
    assert stream_types("task:" <> task_id(id, slot)) == ["TaskCreated"]
    assert stream_types("schedule:#{ctx.p}:#{id}") == ["ScheduleCreated", "ScheduleFired"]
  end

  # (2) ---------------------------------------------------------------------

  test "a restarted ticker does not fire the slot again", ctx do
    id = create_schedule(ctx)
    slot = first_slot(ctx, id)
    set_clock(ctx, slot + 5)
    start_ticker(ctx)
    :ok = Ticker.tick_now()

    restart_ticker(ctx)
    :ok = Ticker.tick_now()

    assert %{fired: 0, errors: 0} = Ticker.stats()
    assert stream_types("schedule:#{ctx.p}:#{id}") == ["ScheduleCreated", "ScheduleFired"]
  end

  # (3) ---------------------------------------------------------------------

  test "after downtime only the latest slot fires, with the older ones counted as collapsed",
       ctx do
    id = create_schedule(ctx, %{misfire_grace_seconds: 7 * 86_400})
    first = first_slot(ctx, id)
    latest = first + 4 * 3_600
    set_clock(ctx, latest + 10)
    start_ticker(ctx)

    :ok = Ticker.tick_now()

    assert %{fired: 1} = Ticker.stats()
    assert ProjectionStore.task_projection(task_id(id, latest))

    for offset <- 0..3 do
      assert ProjectionStore.task_projection(task_id(id, first + offset * 3_600)) == nil
    end

    # Slots first..latest were due; the latest fired, the other four collapsed.
    assert %{last_slot: ^latest, last_outcome: %{kind: "fired", missed_count: 4}} =
             schedule(ctx, id)
  end

  test "past the grace nothing fires, one skip records the count, and the slot never refires",
       ctx do
    id = create_schedule(ctx)
    first = first_slot(ctx, id)
    late = first + 4 * 3_600
    set_clock(ctx, late + 1_200)
    start_ticker(ctx)

    :ok = Ticker.tick_now()

    assert %{fired: 0, skipped: 1} = Ticker.stats()

    assert %{
             last_slot: ^late,
             last_outcome: %{kind: "skipped", reason: "missed", missed_count: 5}
           } = schedule(ctx, id)

    for offset <- 0..4,
        do: assert(ProjectionStore.task_projection(task_id(id, first + offset * 3_600)) == nil)

    :ok = Ticker.tick_now()
    assert %{skipped: 1} = Ticker.stats()

    set_clock(ctx, late + 3_600 + 5)
    :ok = Ticker.tick_now()
    assert %{fired: 1} = Ticker.stats()
    assert ProjectionStore.task_projection(task_id(id, late + 3_600))
    assert ProjectionStore.task_projection(task_id(id, late)) == nil
  end

  # (4) ---------------------------------------------------------------------

  test "crash after task.create and before mark_fired: recovery finishes the fire without a duplicate",
       ctx do
    id = create_schedule(ctx)
    slot = first_slot(ctx, id)
    set_clock(ctx, slot + 5)
    FaultDispatch.put([{"schedule.mark_fired", id, {:error, :timeout}}])
    start_ticker(ctx, dispatch: FaultDispatch)

    :ok = Ticker.tick_now()

    assert %{errors: 1, fired: 0} = Ticker.stats()
    assert ProjectionStore.task_projection(task_id(id, slot))
    assert %{last_slot: nil} = schedule(ctx, id)
    assert %{status: "recorded"} = intent("#{id}:#{slot}")

    FaultDispatch.clear()
    restart_ticker(ctx)
    # `stats/0` is a call: it runs after the boot-time recovery continuation.
    assert %{errors: 0} = Ticker.stats()

    assert %{last_slot: ^slot, last_outcome: %{kind: "fired"}} = schedule(ctx, id)
    assert %{status: "confirmed"} = intent("#{id}:#{slot}")
    assert stream_types("task:" <> task_id(id, slot)) == ["TaskCreated"]
  end

  test "recovery with a task that already exists under another command id creates no duplicate",
       ctx do
    id = create_schedule(ctx)
    slot = first_slot(ctx, id)
    tid = task_id(id, slot)

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: "earlier-attempt-#{tid}",
               aggregate_id: "task:" <> tid,
               type: "task.create",
               payload: %{task_id: tid, project_id: ctx.p, title: "t", provider_tracked: false}
             })

    {:ok, _} =
      Recovery.record_intent("#{id}:#{slot}", %{
        schedule_id: id,
        project_id: ctx.p,
        slot: slot,
        task_id: tid
      })

    set_clock(ctx, slot + 5)
    start_ticker(ctx)

    assert %{errors: 0} = Ticker.stats()
    assert %{last_slot: ^slot, last_outcome: %{kind: "fired"}} = schedule(ctx, id)
    assert %{status: "confirmed"} = intent("#{id}:#{slot}")
    assert stream_types("task:" <> tid) == ["TaskCreated"]
  end

  test "recovery skips the intent of a deleted schedule and marks a legacy intent stale", ctx do
    id = create_schedule(ctx)
    slot = first_slot(ctx, id)

    {:ok, _} =
      Recovery.record_intent("#{id}:#{slot}", %{schedule_id: id, project_id: ctx.p, slot: slot})

    operator(ctx, "schedule.delete", id)

    legacy = "legacy-#{Elixir.EventStore.UUID.uuid4()}"
    {:ok, _} = Recovery.record_intent(legacy, %{run_id: "r"})

    set_clock(ctx, slot + 5)
    start_ticker(ctx)
    assert %{errors: 0} = Ticker.stats()

    assert %{status: "skipped"} = intent("#{id}:#{slot}")
    assert %{status: "stale"} = intent(legacy)
    assert ProjectionStore.task_projection(task_id(id, slot)) == nil
  end

  # (5) ---------------------------------------------------------------------

  test "a paused project records a project_paused skip and creates no task", ctx do
    id = create_schedule(ctx)
    slot = first_slot(ctx, id)

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectPaused", payload: %{project_id: ctx.p}}
      ])

    set_clock(ctx, slot + 5)
    start_ticker(ctx)

    :ok = Ticker.tick_now()

    assert %{last_slot: ^slot, last_outcome: %{kind: "skipped", reason: "project_paused"}} =
             schedule(ctx, id)

    assert ProjectionStore.task_projection(task_id(id, slot)) == nil
  end

  test "a reached daily thread cap records a daily_cap skip", ctx do
    capped = "cap-#{Elixir.EventStore.UUID.uuid4()}"
    register_project(capped, %{daily_thread_cap: 1})
    id = create_schedule(ctx, %{project_id: capped})
    slot = first_slot(ctx, id, capped)
    now = DateTime.from_unix!(slot + 5)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectThreadStarted",
          payload: %{
            project_id: capped,
            thread_id: "r-1",
            thread_kind: "run",
            day: ForemanServer.ProjectLimits.day(now)
          }
        }
      ])

    set_clock(ctx, slot + 5)
    start_ticker(ctx)
    :ok = Ticker.tick_now()

    assert %{last_outcome: %{kind: "skipped", reason: "daily_cap"}} =
             ProjectionStore.schedule(capped, id)

    assert ProjectionStore.task_projection(task_id(id, slot)) == nil
  end

  # (6) ---------------------------------------------------------------------

  test "overlap: a still-open previous task skips the next slot; once closed the next slot fires",
       ctx do
    id = create_schedule(ctx)
    first = first_slot(ctx, id)
    set_clock(ctx, first + 5)
    start_ticker(ctx)
    :ok = Ticker.tick_now()

    second = first + 3_600
    set_clock(ctx, second + 5)
    :ok = Ticker.tick_now()

    assert %{last_slot: ^second, last_outcome: %{kind: "skipped", reason: "overlap"}} =
             schedule(ctx, id)

    assert ProjectionStore.task_projection(task_id(id, second)) == nil

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: "close-#{id}",
               aggregate_id: "task:" <> task_id(id, first),
               type: "task.update",
               payload: %{task_id: task_id(id, first), status: "closed"}
             })

    third = second + 3_600
    set_clock(ctx, third + 5)
    :ok = Ticker.tick_now()

    assert %{last_slot: ^third, last_outcome: %{kind: "fired"}} = schedule(ctx, id)
    assert ProjectionStore.task_projection(task_id(id, third))
  end

  # (7) ---------------------------------------------------------------------

  test "auto_approve approves the task; without it the task stays an open proposal", ctx do
    proposal = create_schedule(ctx, %{auto_approve: false})
    approved = create_schedule(ctx, %{auto_approve: true})
    slot = max(first_slot(ctx, proposal), first_slot(ctx, approved))
    set_clock(ctx, slot + 5)
    start_ticker(ctx)

    :ok = Ticker.tick_now()

    assert %{status: "open", approval_id: nil} =
             ProjectionStore.task_projection(task_id(proposal, slot))

    assert %{approval_id: approval_id} = ProjectionStore.task_projection(task_id(approved, slot))
    assert is_binary(approval_id)
    assert "TaskApproved" in stream_types("task:" <> task_id(approved, slot))
    refute "TaskApproved" in stream_types("task:" <> task_id(proposal, slot))
  end

  # (8) ---------------------------------------------------------------------

  test "paused and deleted schedules never fire", ctx do
    paused = create_schedule(ctx)
    deleted = create_schedule(ctx)
    slot = max(first_slot(ctx, paused), first_slot(ctx, deleted))
    operator(ctx, "schedule.pause", paused)
    operator(ctx, "schedule.delete", deleted)
    set_clock(ctx, slot + 5)
    start_ticker(ctx)

    :ok = Ticker.tick_now()

    assert %{fired: 0, skipped: 0, errors: 0} = Ticker.stats()
    assert ProjectionStore.task_projection(task_id(paused, slot)) == nil
    assert ProjectionStore.task_projection(task_id(deleted, slot)) == nil
  end

  # (9) ---------------------------------------------------------------------

  test "a typed task.create rejection is a recorded error skip and does not stop another schedule",
       ctx do
    bad = create_schedule(ctx, %{name: "a-bad"})
    good = create_schedule(ctx, %{name: "z-good"})
    slot = max(first_slot(ctx, bad), first_slot(ctx, good))
    set_clock(ctx, slot + 5)
    FaultDispatch.put([{"task.create", bad, {:error, {:unknown_workflow, "gone"}}}])
    start_ticker(ctx, dispatch: FaultDispatch)

    :ok = Ticker.tick_now()

    assert %{skipped: 1, fired: 1, errors: 0} = Ticker.stats()

    assert %{last_slot: ^slot, last_outcome: %{kind: "skipped", reason: "error"}} =
             schedule(ctx, bad)

    assert %{last_outcome: %{kind: "fired"}} = schedule(ctx, good)
    # The intent for the rejected fire is confirmed, not left to be redone forever.
    assert %{status: "confirmed"} = intent("#{bad}:#{slot}")
  end

  test "a crashing schedule increments errors and the healthy one still fires", ctx do
    bad = create_schedule(ctx, %{name: "a-crash"})
    good = create_schedule(ctx, %{name: "z-fine"})
    slot = max(first_slot(ctx, bad), first_slot(ctx, good))
    set_clock(ctx, slot + 5)
    FaultDispatch.put([{"task.create", bad, {:raise, "boom"}}])
    start_ticker(ctx, dispatch: FaultDispatch)

    :ok = Ticker.tick_now()

    assert %{errors: 1, fired: 1} = Ticker.stats()
    assert %{last_slot: nil} = schedule(ctx, bad)
    assert %{last_outcome: %{kind: "fired"}} = schedule(ctx, good)
  end
end
