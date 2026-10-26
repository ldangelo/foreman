defmodule ForemanServer.Schedule.TickerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

    def dispatch_system_approval(command) do
      case fault(command) do
        nil -> CommandGateway.dispatch_system_approval(command)
        {:raise, message} -> raise message
        result -> result
      end
    end

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

  # The approval keeps failing with an error nobody classified, so the fire stays
  # unfinished: `create` succeeded, the slot is not consumed.
  defp unfinished_fire(ctx) do
    id = create_schedule(ctx, %{auto_approve: true})
    slot = first_slot(ctx, id)
    set_clock(ctx, slot + 5)
    FaultDispatch.put([{"task.approve", id, {:error, :router_unavailable}}])
    start_ticker(ctx, dispatch: FaultDispatch)
    capture_log(fn -> :ok = Ticker.tick_now() end)

    assert %{errors: 1} = Ticker.stats()
    assert ProjectionStore.task_projection(task_id(id, slot))
    assert %{last_slot: nil} = schedule(ctx, id)
    {id, slot}
  end

  defp record_intent!(ctx, id, slot) do
    assert {:ok, _} =
             Recovery.record_intent("#{id}:#{slot}", %{
               schedule_id: id,
               project_id: ctx.p,
               slot: slot,
               task_id: task_id(id, slot)
             })

    :ok
  end

  # The task a fire created before it crashed, under a command id of its own.
  defp create_task_elsewhere!(ctx, id, slot) do
    tid = task_id(id, slot)

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: "earlier-attempt-#{tid}",
               aggregate_id: "task:" <> tid,
               type: "task.create",
               payload: %{task_id: tid, project_id: ctx.p, title: "t", provider_tracked: false}
             })

    tid
  end

  defp mark_fired!(ctx, id, slot, tid) do
    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: "manual-fired-#{id}-#{slot}",
               aggregate_id: "schedule:#{ctx.p}:#{id}",
               type: "schedule.mark_fired",
               payload: %{
                 schedule_id: id,
                 project_id: ctx.p,
                 slot: slot,
                 task_id: tid,
                 intent_id: "#{id}:#{slot}",
                 collapsed_count: 0,
                 at: DateTime.to_iso8601(DateTime.from_unix!(slot))
               }
             })

    :ok
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

  test "a deterministic task.create rejection is a recorded error skip and does not stop another schedule",
       ctx do
    bad = create_schedule(ctx, %{name: "a-bad"})
    good = create_schedule(ctx, %{name: "z-good"})
    slot = max(first_slot(ctx, bad), first_slot(ctx, good))
    set_clock(ctx, slot + 5)
    FaultDispatch.put([{"task.create", bad, {:error, {:missing_or_invalid, :task_id}}}])
    start_ticker(ctx, dispatch: FaultDispatch)

    :ok = Ticker.tick_now()

    assert %{skipped: 1, fired: 1, errors: 0} = Ticker.stats()

    assert %{last_slot: ^slot, last_outcome: %{kind: "skipped", reason: "error"}} =
             schedule(ctx, bad)

    assert %{last_outcome: %{kind: "fired"}} = schedule(ctx, good)
    # The intent for the rejected fire is confirmed, not left to be redone forever.
    assert %{status: "confirmed"} = intent("#{bad}:#{slot}")
  end

  test "each deterministic task.create rejection is recorded under its own skip reason", ctx do
    rejections = [
      {{:project_paused, ctx.p}, "project_paused"},
      {{:project_archived, ctx.p}, "project_paused"},
      {{:missing_or_invalid, :task_id}, "error"},
      {{:invalid_task_status, "bogus"}, "error"},
      {:project_id_required, "error"}
    ]

    cases = for {rejection, reason} <- rejections, do: {create_schedule(ctx), rejection, reason}
    slot = cases |> Enum.map(fn {id, _, _} -> first_slot(ctx, id) end) |> Enum.max()
    set_clock(ctx, slot + 5)

    FaultDispatch.put(
      for {id, rejection, _reason} <- cases, do: {"task.create", id, {:error, rejection}}
    )

    start_ticker(ctx, dispatch: FaultDispatch)

    :ok = Ticker.tick_now()

    assert %{skipped: 5, fired: 0, errors: 0} = Ticker.stats()

    for {id, _rejection, reason} <- cases do
      assert %{last_slot: ^slot, last_outcome: %{kind: "skipped", reason: ^reason}} =
               schedule(ctx, id)

      assert ProjectionStore.task_projection(task_id(id, slot)) == nil
      assert %{status: "confirmed"} = intent("#{id}:#{slot}")
    end
  end

  # (10) --------------------------------------------------------------------

  # Shapes the ticker does not classify: infrastructure failures, and a typed tag that
  # `task.create` never returns. None of them is a recorded outcome: the intent stays and
  # the next tick retries the same commands.
  @unclassified [
    :timeout,
    {:wrong_expected_version, 3},
    :projection_recovery_failed,
    :noproc,
    {:actor_down, :noproc},
    :router_unavailable,
    {:unknown_workflow, "gone"},
    "boom",
    %{code: :overloaded}
  ]

  test "an error nobody classified is retried on the next tick, never recorded as a skip", ctx do
    cases = for error <- @unclassified, do: {create_schedule(ctx), error}
    slot = cases |> Enum.map(fn {id, _} -> first_slot(ctx, id) end) |> Enum.max()
    set_clock(ctx, slot + 5)
    FaultDispatch.put(for {id, error} <- cases, do: {"task.create", id, {:error, error}})
    start_ticker(ctx, dispatch: FaultDispatch)

    capture_log(fn -> :ok = Ticker.tick_now() end)

    n = length(cases)
    assert %{errors: ^n, skipped: 0, fired: 0} = Ticker.stats()

    for {id, _error} <- cases do
      assert %{last_slot: nil} = schedule(ctx, id)
      assert %{status: "recorded"} = intent("#{id}:#{slot}")
      assert ProjectionStore.task_projection(task_id(id, slot)) == nil
    end

    FaultDispatch.clear()
    :ok = Ticker.tick_now()

    assert %{errors: ^n, skipped: 0, fired: ^n} = Ticker.stats()

    for {id, _error} <- cases do
      assert %{last_slot: ^slot, last_outcome: %{kind: "fired"}} = schedule(ctx, id)
      assert %{status: "confirmed"} = intent("#{id}:#{slot}")
      assert stream_types("task:" <> task_id(id, slot)) == ["TaskCreated"]
    end
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

  # (11) --------------------------------------------------------------------

  describe "task.approve refused after task.create" do
    test "a deterministic refusal records the fire with its task: no skip, no orphan, no second task",
         ctx do
      id = create_schedule(ctx, %{auto_approve: true})
      slot = first_slot(ctx, id)
      tid = task_id(id, slot)
      set_clock(ctx, slot + 5)
      FaultDispatch.put([{"task.approve", id, {:error, {:project_paused, ctx.p}}}])
      start_ticker(ctx, dispatch: FaultDispatch)

      log = capture_log(fn -> :ok = Ticker.tick_now() end)

      # Surfaced, not swallowed: the log names the task and the refusal.
      assert log =~ "task.approve for #{tid} was rejected"
      assert log =~ "project_paused"
      assert %{fired: 1, skipped: 0, errors: 0} = Ticker.stats()

      # The slot is fired with its task, which stays an open proposal ...
      assert %{status: "open", approval_id: nil} = ProjectionStore.task_projection(tid)

      assert %{last_slot: ^slot, last_outcome: %{kind: "fired", slot: ^slot}, last_task_id: ^tid} =
               schedule(ctx, id)

      assert %{status: "confirmed"} = intent("#{id}:#{slot}")
      assert stream_types("schedule:#{ctx.p}:#{id}") == ["ScheduleCreated", "ScheduleFired"]

      # ... so the overlap check sees the pending task: the next slot is skipped beside it.
      second = slot + 3_600
      set_clock(ctx, second + 5)
      :ok = Ticker.tick_now()

      assert %{last_slot: ^second, last_outcome: %{kind: "skipped", reason: "overlap"}} =
               schedule(ctx, id)

      # A restart finds nothing to redo and creates no second task.
      restart_ticker(ctx)
      assert %{errors: 0} = Ticker.stats()
      assert stream_types("task:" <> tid) == ["TaskCreated"]
      assert ProjectionStore.task_projection(task_id(id, second)) == nil
    end

    test "every deterministic refusal is recorded the same way", ctx do
      refusals = [
        {:project_paused, ctx.p},
        {:project_archived, ctx.p},
        {:task_not_approvable, "ready"},
        {:workflow_load_failed, "gone", :enoent},
        {:implementation_context_failed, :trd_path_missing}
      ]

      cases = for refusal <- refusals, do: {create_schedule(ctx, %{auto_approve: true}), refusal}
      slot = cases |> Enum.map(fn {id, _} -> first_slot(ctx, id) end) |> Enum.max()
      set_clock(ctx, slot + 5)

      FaultDispatch.put(for {id, refusal} <- cases, do: {"task.approve", id, {:error, refusal}})

      start_ticker(ctx, dispatch: FaultDispatch)

      capture_log(fn -> :ok = Ticker.tick_now() end)

      assert %{fired: 5, skipped: 0, errors: 0} = Ticker.stats()

      for {id, _refusal} <- cases do
        tid = task_id(id, slot)

        assert %{last_slot: ^slot, last_outcome: %{kind: "fired"}, last_task_id: ^tid} =
                 schedule(ctx, id)

        assert %{status: "open", approval_id: nil} = ProjectionStore.task_projection(tid)
        assert %{status: "confirmed"} = intent("#{id}:#{slot}")
      end
    end

    test "an unclassified approve failure keeps the intent; the retry approves the same task",
         ctx do
      # `:task_not_found` and `:not_found` are not refusals: a task that was just created
      # cannot be missing, so they are retried like any shape the ticker does not know.
      errors = [:router_unavailable, :timeout, {:task_not_found, "x"}, {:not_found, :task, "x"}]
      cases = for error <- errors, do: {create_schedule(ctx, %{auto_approve: true}), error}
      slot = cases |> Enum.map(fn {id, _} -> first_slot(ctx, id) end) |> Enum.max()
      set_clock(ctx, slot + 5)
      FaultDispatch.put(for {id, error} <- cases, do: {"task.approve", id, {:error, error}})
      start_ticker(ctx, dispatch: FaultDispatch)

      capture_log(fn -> :ok = Ticker.tick_now() end)

      n = length(cases)
      assert %{fired: 0, skipped: 0, errors: ^n} = Ticker.stats()

      for {id, _error} <- cases do
        assert %{last_slot: nil} = schedule(ctx, id)
        assert %{status: "recorded"} = intent("#{id}:#{slot}")
        assert %{approval_id: nil} = ProjectionStore.task_projection(task_id(id, slot))
      end

      FaultDispatch.clear()
      :ok = Ticker.tick_now()

      assert %{fired: ^n, skipped: 0, errors: ^n} = Ticker.stats()

      for {id, _error} <- cases do
        tid = task_id(id, slot)
        assert %{approval_id: approval_id} = ProjectionStore.task_projection(tid)
        assert is_binary(approval_id)

        assert %{last_slot: ^slot, last_outcome: %{kind: "fired"}, last_task_id: ^tid} =
                 schedule(ctx, id)

        # The dispatcher may append `TaskDispatched` after the approval, so not an exact list.
        types = stream_types("task:" <> tid)
        assert Enum.count(types, &(&1 == "TaskCreated")) == 1
        assert "TaskApproved" in types
      end
    end
  end

  # (12) --------------------------------------------------------------------

  describe "a skip decision never orphans a task" do
    test "a slot that turns late after its task was created is fired, not skipped as missed",
         ctx do
      {id, slot} = unfinished_fire(ctx)
      tid = task_id(id, slot)

      # Past the grace the planner decides `missed` ...
      set_clock(ctx, slot + 700)
      log = capture_log(fn -> :ok = Ticker.tick_now() end)

      # ... but the task exists, so the slot is recorded as fired and the task left un-approved.
      assert log =~ "not skipped as missed"
      assert %{fired: 1, skipped: 0, errors: 1} = Ticker.stats()

      assert %{last_slot: ^slot, last_outcome: %{kind: "fired"}, last_task_id: ^tid} =
               schedule(ctx, id)

      assert %{status: "open", approval_id: nil} = ProjectionStore.task_projection(tid)
      assert %{status: "confirmed"} = intent("#{id}:#{slot}")
      assert stream_types("schedule:#{ctx.p}:#{id}") == ["ScheduleCreated", "ScheduleFired"]
    end

    test "a project paused after the task was created does not turn its slot into a skip", ctx do
      {id, slot} = unfinished_fire(ctx)
      tid = task_id(id, slot)

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "ProjectPaused", payload: %{project_id: ctx.p}}
        ])

      log = capture_log(fn -> :ok = Ticker.tick_now() end)

      assert log =~ "not skipped as project_paused"

      assert %{last_slot: ^slot, last_outcome: %{kind: "fired"}, last_task_id: ^tid} =
               schedule(ctx, id)

      assert %{status: "open", approval_id: nil} = ProjectionStore.task_projection(tid)
      assert stream_types("schedule:#{ctx.p}:#{id}") == ["ScheduleCreated", "ScheduleFired"]
    end
  end

  # (13) --------------------------------------------------------------------

  describe "recovery applies the planner's rules to the intent's slot" do
    test "a late slot without a task is recorded as missed and confirmed; nothing is created",
         ctx do
      id = create_schedule(ctx, %{auto_approve: true})
      slot = first_slot(ctx, id)
      record_intent!(ctx, id, slot)
      set_clock(ctx, slot + 3_000)
      start_ticker(ctx)

      # `stats/0` is a call: it runs after the boot-time recovery continuation.
      assert %{fired: 0, skipped: 1, errors: 0} = Ticker.stats()

      assert %{
               last_slot: ^slot,
               last_outcome: %{kind: "skipped", reason: "missed", missed_count: 1}
             } = schedule(ctx, id)

      assert ProjectionStore.task_projection(task_id(id, slot)) == nil
      assert %{status: "confirmed"} = intent("#{id}:#{slot}")

      # The slot is consumed: the next tick does not run it either.
      :ok = Ticker.tick_now()
      assert %{fired: 0, skipped: 1, errors: 0} = Ticker.stats()
      assert ProjectionStore.task_projection(task_id(id, slot)) == nil
    end

    test "the boundary is the planner's: exactly the grace late is redone, a second more is missed",
         ctx do
      on_time = create_schedule(ctx, %{misfire_grace_seconds: 600})
      late = create_schedule(ctx, %{misfire_grace_seconds: 599})
      slot = max(first_slot(ctx, on_time), first_slot(ctx, late))
      record_intent!(ctx, on_time, slot)
      record_intent!(ctx, late, slot)
      set_clock(ctx, slot + 600)
      start_ticker(ctx)

      assert %{fired: 1, skipped: 1, errors: 0} = Ticker.stats()
      assert %{last_outcome: %{kind: "fired"}} = schedule(ctx, on_time)
      assert ProjectionStore.task_projection(task_id(on_time, slot))

      assert %{last_outcome: %{kind: "skipped", reason: "missed"}} = schedule(ctx, late)
      assert ProjectionStore.task_projection(task_id(late, slot)) == nil
    end

    test "a late slot whose task already exists is recorded as fired and left un-approved",
         ctx do
      id = create_schedule(ctx, %{auto_approve: true})
      slot = first_slot(ctx, id)
      tid = create_task_elsewhere!(ctx, id, slot)
      record_intent!(ctx, id, slot)
      set_clock(ctx, slot + 3_000)
      start_ticker(ctx)

      assert %{fired: 1, skipped: 0, errors: 0} = Ticker.stats()

      assert %{last_slot: ^slot, last_outcome: %{kind: "fired"}, last_task_id: ^tid} =
               schedule(ctx, id)

      assert %{status: "open", approval_id: nil} = ProjectionStore.task_projection(tid)
      assert %{status: "confirmed"} = intent("#{id}:#{slot}")
      assert stream_types("task:" <> tid) == ["TaskCreated"]
    end

    test "a slot the schedule already accounts for creates no task and its intent is closed",
         ctx do
      # A week of grace: lateness plays no part, only the accounting does.
      superseded = create_schedule(ctx, %{misfire_grace_seconds: 7 * 86_400})
      first = first_slot(ctx, superseded)
      later = first + 3_600
      mark_fired!(ctx, superseded, later, "t-later")
      record_intent!(ctx, superseded, first)

      # Never fired since creation: a slot before the baseline (`active_since`) never counts.
      fresh = create_schedule(ctx, %{misfire_grace_seconds: 7 * 86_400})
      before_baseline = first_slot(ctx, fresh) - 3_600
      record_intent!(ctx, fresh, before_baseline)

      set_clock(ctx, later + 5)
      start_ticker(ctx)

      assert %{fired: 0, skipped: 2, errors: 0} = Ticker.stats()
      assert %{status: "skipped"} = intent("#{superseded}:#{first}")
      assert %{status: "skipped"} = intent("#{fresh}:#{before_baseline}")
      assert ProjectionStore.task_projection(task_id(superseded, first)) == nil
      assert ProjectionStore.task_projection(task_id(fresh, before_baseline)) == nil

      assert stream_types("schedule:#{ctx.p}:#{superseded}") == [
               "ScheduleCreated",
               "ScheduleFired"
             ]

      assert stream_types("schedule:#{ctx.p}:#{fresh}") == ["ScheduleCreated"]
    end

    test "an interrupted intent of a fire that was already recorded is confirmed without a second task",
         ctx do
      id = create_schedule(ctx, %{auto_approve: true})
      slot = first_slot(ctx, id)
      tid = create_task_elsewhere!(ctx, id, slot)
      mark_fired!(ctx, id, slot, tid)
      record_intent!(ctx, id, slot)
      set_clock(ctx, slot + 5)
      start_ticker(ctx)

      assert %{fired: 1, skipped: 0, errors: 0} = Ticker.stats()
      assert %{status: "confirmed"} = intent("#{id}:#{slot}")
      assert stream_types("task:" <> tid) == ["TaskCreated"]
      assert stream_types("schedule:#{ctx.p}:#{id}") == ["ScheduleCreated", "ScheduleFired"]
      assert %{approval_id: nil} = ProjectionStore.task_projection(tid)
    end
  end
end
