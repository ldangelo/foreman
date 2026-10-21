defmodule ForemanServer.Schedule.Ticker do
  @moduledoc """
  Supervised runtime that turns due schedule slots into tasks, exactly once.

  Each tick (default every 30 s) loads `ProjectionStore.all_active_schedules/0`
  and, per schedule, asks the pure `Schedule.Planner` for ONE decision. A fire is
  a four-step sequence in which every step has a deterministic command id derived
  from `<schedule_id>` and the slot (unix seconds), so any prefix of it can be
  replayed after a crash and converge on the same events:

    1. `scheduler_intent.record` (`<schedule_id>:<slot>`) - the crash marker
    2. `task.create` (`sched-<schedule_id>-<slot>`), then `task.approve` when the
       schedule is `auto_approve` (otherwise the task stays `open` as a proposal)
    3. `schedule.mark_fired` - advances `last_slot`; a repeated slot is
       `slot_already_processed`
    4. `scheduler_intent.confirm`

  A skip decision dispatches `schedule.skip_fire`, which consumes the slot so it
  is never retried. Tasks are created ad hoc (`provider_tracked: false`): a
  scheduled task creates no tracker issue per fire.

  ## Recovery

  On boot and every `recover_every` ticks, `Recovery.interrupted_intents/2` lists
  intents recorded but never confirmed for longer than `recovery_grace_ms`. Each
  is redone from step 2 using the schedule re-read from the projection (all steps
  are idempotent); an intent whose schedule was deleted is skipped, and a legacy
  intent with no schedule/slot is marked stale.

  ## Failure isolation

  Every schedule is handled in its own unlinked task under a private
  `Task.Supervisor`; a crash or timeout in one increments `stats.errors` and never
  stops the tick. A dispatch that raises or exits leaves the intent `recorded`, so
  recovery redoes it. Deterministic domain rejections (`{:error, {tag, ...}}`) of
  `task.create`/`task.approve` become a recorded `error` skip instead.

  Options: `:now_fun` (`(-> DateTime.t())`), `:interval_ms` (0 = no timer, tests
  drive `tick_now/1`), `:dispatch` (module with `dispatch_system/1` and
  `dispatch_system_approval/1`, default `CommandGateway`), `:recovery_grace_ms`
  (default 120_000), `:recover_every` (ticks, default 20), `:schedule_timeout_ms`.
  """

  use GenServer
  require Logger

  alias ForemanServer.{CommandGateway, ProjectionStore, Recovery}
  alias ForemanServer.Aggregates.Schedule, as: ScheduleAggregate
  alias ForemanServer.Schedule.{Planner, Spec}

  @default_interval_ms 30_000
  @default_recovery_grace_ms 120_000
  @default_recover_every 20
  @default_schedule_timeout_ms 30_000

  @type stats :: %{
          last_tick_at: String.t() | nil,
          fired: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }

  # ---------------------------------------------------------------------------
  # API
  # ---------------------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the ticker is enabled by config (`:schedule, :ticker_enabled`)."
  @spec enabled?() :: boolean()
  def enabled? do
    :foreman_server |> Application.get_env(:schedule, []) |> Keyword.get(:ticker_enabled, false)
  end

  @doc "True when the ticker process is alive (what a schedule list reports as `running`)."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @doc "Synchronously run one tick at `now` (defaults to the injected clock)."
  @spec tick_now(DateTime.t() | nil) :: :ok
  def tick_now(now \\ nil), do: GenServer.call(__MODULE__, {:tick_now, now}, :infinity)

  @spec stats() :: stats()
  def stats, do: GenServer.call(__MODULE__, :stats)

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, sup} = Task.Supervisor.start_link()
    config = Application.get_env(:foreman_server, :schedule, [])

    state = %{
      sup: sup,
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          Keyword.get(config, :tick_interval_ms, @default_interval_ms)
        ),
      dispatch: Keyword.get(opts, :dispatch, CommandGateway),
      recovery_grace_ms: Keyword.get(opts, :recovery_grace_ms, @default_recovery_grace_ms),
      recover_every: Keyword.get(opts, :recover_every, @default_recover_every),
      schedule_timeout_ms: Keyword.get(opts, :schedule_timeout_ms, @default_schedule_timeout_ms),
      ticks: 0,
      stats: %{last_tick_at: nil, fired: 0, skipped: 0, errors: 0}
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    state = recover(state, state.now_fun.())
    schedule_next(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:tick_now, now}, _from, state) do
    {:reply, :ok, run_tick(state, now || state.now_fun.())}
  end

  def handle_call(:stats, _from, state), do: {:reply, state.stats, state}

  @impl true
  def handle_info(:tick, state) do
    state = run_tick(state, state.now_fun.())
    schedule_next(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule_next(%{interval_ms: ms}) when is_integer(ms) and ms > 0,
    do: Process.send_after(self(), :tick, ms)

  defp schedule_next(_state), do: :ok

  # ---------------------------------------------------------------------------
  # Tick
  # ---------------------------------------------------------------------------

  defp run_tick(state, now) do
    state = %{state | ticks: state.ticks + 1}

    state =
      if state.recover_every > 0 and rem(state.ticks, state.recover_every) == 0,
        do: recover(state, now),
        else: state

    results =
      ProjectionStore.all_active_schedules()
      |> Enum.map(&isolated(state, fn -> tick_schedule(state, &1, now) end))

    state
    |> bump(results)
    |> put_in([:stats, :last_tick_at], DateTime.to_iso8601(now))
  end

  defp tick_schedule(state, schedule, now) do
    ctx = build_ctx(schedule, now)

    case Planner.plan(schedule, now, ctx) do
      :wait ->
        :wait

      {:fire, slot} ->
        fire(state, schedule, slot, collapsed_count(schedule, slot), now)

      {:skip, slot, reason, missed} ->
        skip(state, schedule, slot, Atom.to_string(reason), missed, nil, now)

      {:error, reason} ->
        Logger.error(
          "Schedule.Ticker schedule=#{schedule.schedule_id} unplannable: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp build_ctx(schedule, now) do
    remaining =
      case ProjectionStore.project_limits(schedule.project_id, now) do
        %{remaining_today: n} when is_integer(n) -> n
        _ -> :unlimited
      end

    %{
      project: ProjectionStore.project(schedule.project_id),
      last_task: schedule.last_task_id && ProjectionStore.task_projection(schedule.last_task_id),
      daily_remaining: remaining
    }
  end

  # Earlier slots collapsed into this fire (due after the lower bound but not fired).
  defp collapsed_count(schedule, slot) do
    with {:ok, spec} <- Spec.parse(schedule.spec) do
      max(
        Spec.missed_count(spec, Planner.lower_bound(schedule), Spec.slot_to_datetime(slot)) - 1,
        0
      )
    else
      _ -> 0
    end
  end

  # ---------------------------------------------------------------------------
  # Fire / skip (all idempotent)
  # ---------------------------------------------------------------------------

  defp fire(state, schedule, slot, collapsed, now) do
    intent_id = intent_id(schedule.schedule_id, slot)
    task_id = task_id(schedule.schedule_id, slot)

    with :ok <- record_intent(schedule, slot, intent_id, task_id, now) do
      complete_fire(state, schedule, slot, collapsed, intent_id, task_id, now)
    end
  end

  # Steps 2-4 (also the recovery redo).
  defp complete_fire(state, schedule, slot, collapsed, intent_id, task_id, now) do
    case create_and_approve(state, schedule, slot, task_id) do
      :ok ->
        with :ok <- mark_fired(state, schedule, slot, task_id, intent_id, collapsed, now),
             :ok <- confirm(intent_id) do
          :fired
        end

      {:skip, reason, detail} ->
        result = skip(state, schedule, slot, reason, nil, detail, now)
        _ = confirm(intent_id)
        result

      {:error, _} = error ->
        error
    end
  end

  defp record_intent(schedule, slot, intent_id, task_id, now) do
    payload = %{
      schedule_id: schedule.schedule_id,
      project_id: schedule.project_id,
      slot: slot,
      task_id: task_id,
      scheduled_for: DateTime.to_iso8601(Spec.slot_to_datetime(slot)),
      scheduled_at: DateTime.to_iso8601(now)
    }

    idempotent(Recovery.record_intent(intent_id, payload), [:scheduler_intent_exists])
  end

  defp create_and_approve(state, schedule, slot, task_id) do
    create = %{
      command_id: "schedule.fire:#{schedule.schedule_id}:#{slot}:task",
      aggregate_id: "task:" <> task_id,
      type: "task.create",
      payload: %{
        task_id: task_id,
        project_id: schedule.project_id,
        title: "#{schedule.name} (#{DateTime.to_iso8601(Spec.slot_to_datetime(slot))})",
        prompt: schedule.prompt,
        task_type: "task",
        workflow_type: schedule.workflow,
        source: "schedule",
        dedupe_key: intent_id(schedule.schedule_id, slot),
        status: "open",
        provider_tracked: false
      }
    }

    with :ok <- step(idempotent(state.dispatch.dispatch_system(create), [:already_exists])) do
      if schedule.auto_approve == true, do: approve(state, schedule, slot, task_id), else: :ok
    end
  end

  defp approve(state, schedule, slot, task_id) do
    command = %{
      command_id: "schedule.fire:#{schedule.schedule_id}:#{slot}:approve",
      aggregate_id: "task:" <> task_id,
      type: "task.approve",
      payload: %{task_id: task_id, approved_by: "scheduler"}
    }

    step(idempotent(state.dispatch.dispatch_system_approval(command), []))
  end

  # Maps the outcome of a task command to the fire sequence's control flow:
  # a paused/archived project is a recorded `project_paused` skip, any other typed
  # domain rejection is a recorded `error` skip, and transient failures (timeouts,
  # version conflicts, unknown shapes) are errors that leave the intent recorded
  # for recovery to redo.
  @transient [:timeout, :wrong_expected_version, :projection_recovery_failed, :noproc]

  defp step(:ok), do: :ok

  defp step({:error, reason} = error) do
    case head(reason) do
      tag when tag in [:project_paused, :project_archived] ->
        {:skip, "project_paused", inspect(reason)}

      tag when is_atom(tag) and tag not in @transient ->
        {:skip, "error", inspect(reason)}

      _ ->
        error
    end
  end

  defp head(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp head(reason) when is_atom(reason), do: reason
  defp head(_reason), do: nil

  defp mark_fired(state, schedule, slot, task_id, intent_id, collapsed, now) do
    command = %{
      command_id: "schedule.fire:#{schedule.schedule_id}:#{slot}:fired",
      aggregate_id: schedule_stream(schedule),
      type: "schedule.mark_fired",
      payload: %{
        schedule_id: schedule.schedule_id,
        project_id: schedule.project_id,
        slot: slot,
        task_id: task_id,
        intent_id: intent_id,
        collapsed_count: collapsed,
        at: DateTime.to_iso8601(now)
      }
    }

    idempotent(state.dispatch.dispatch_system(command), [
      :slot_already_processed,
      :schedule_deleted
    ])
  end

  defp confirm(intent_id),
    do: idempotent(Recovery.confirm_execution(intent_id), [:scheduler_intent_terminal])

  defp skip(state, schedule, slot, reason, missed, detail, now) do
    command = %{
      command_id: "schedule.skip:#{schedule.schedule_id}:#{slot}",
      aggregate_id: schedule_stream(schedule),
      type: "schedule.skip_fire",
      payload: %{
        schedule_id: schedule.schedule_id,
        project_id: schedule.project_id,
        slot: slot,
        reason: reason,
        missed_count: missed,
        detail: detail,
        at: DateTime.to_iso8601(now)
      }
    }

    case idempotent(state.dispatch.dispatch_system(command), [
           :slot_already_processed,
           :schedule_deleted
         ]) do
      :ok -> :skipped
      {:error, _} = error -> error
    end
  end

  # `{:ok, _}` and tolerated typed errors are success; everything else is an error.
  defp idempotent({:ok, _}, _tolerated), do: :ok

  defp idempotent({:error, reason}, tolerated) do
    if is_tuple(reason) and tuple_size(reason) > 0 and elem(reason, 0) in tolerated,
      do: :ok,
      else: {:error, reason}
  end

  defp idempotent({:error, reason, _detail}, tolerated),
    do: idempotent({:error, reason}, tolerated)

  defp schedule_stream(schedule),
    do: ScheduleAggregate.stream_id(schedule.project_id, schedule.schedule_id)

  defp intent_id(schedule_id, slot), do: "#{schedule_id}:#{slot}"
  defp task_id(schedule_id, slot), do: "sched-#{schedule_id}-#{slot}"

  # ---------------------------------------------------------------------------
  # Recovery
  # ---------------------------------------------------------------------------

  defp recover(state, now) do
    now_ms = DateTime.to_unix(now, :millisecond)

    results =
      now_ms
      |> Recovery.interrupted_intents(state.recovery_grace_ms)
      |> Enum.map(&isolated(state, fn -> redo(state, &1, now) end))

    bump(state, results)
  end

  defp redo(
         state,
         %{intent_id: intent_id, schedule_id: sid, project_id: pid, slot: slot} = intent,
         now
       )
       when is_binary(sid) and is_binary(pid) and is_integer(slot) do
    case ProjectionStore.schedule(pid, sid) do
      %{status: status} = schedule when status != "deleted" ->
        task_id = Map.get(intent, :task_id) || task_id(sid, slot)
        complete_fire(state, schedule, slot, nil, intent_id, task_id, now)

      _deleted_or_missing ->
        idempotent(Recovery.skip_fire(intent_id, "schedule_deleted"), [:scheduler_intent_terminal])

        :skipped
    end
  end

  defp redo(_state, intent, _now) do
    # Legacy intent with no schedule/slot: it can never be redone.
    _ = Recovery.mark_interrupted(intent)
    :skipped
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp isolated(state, fun) do
    task = Task.Supervisor.async_nolink(state.sup, fun)

    case Task.yield(task, state.schedule_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        Logger.error("Schedule.Ticker schedule task crashed: #{inspect(reason)}")
        {:error, {:crashed, reason}}

      nil ->
        Logger.error("Schedule.Ticker schedule task timed out")
        {:error, :timeout}
    end
  end

  defp bump(state, results) do
    Enum.reduce(results, state, fn
      :fired, acc ->
        update_in(acc.stats.fired, &(&1 + 1))

      :skipped, acc ->
        update_in(acc.stats.skipped, &(&1 + 1))

      {:error, reason}, acc ->
        Logger.error("Schedule.Ticker error: #{inspect(reason)}")
        update_in(acc.stats.errors, &(&1 + 1))

      _wait, acc ->
        acc
    end)
  end
end
