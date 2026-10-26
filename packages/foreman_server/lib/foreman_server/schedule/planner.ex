defmodule ForemanServer.Schedule.Planner do
  @moduledoc """
  Pure per-schedule decision: fire, skip, or wait. No clock, no process access:
  `now` and every fact about the world arrive as arguments (`Schedule.Ticker`
  assembles `ctx` from `ProjectionStore`).

  ## Precedence

  Exactly one decision is returned. Only the single latest due slot is ever
  considered (`Spec.latest_slot_at_or_before/3`), so downtime cannot produce a
  burst. Evaluated in this order, first match wins:

    1. no due slot after `max(last_slot, active_since)` -> `:wait`
    2. `misfired?/3` (`now - slot > misfire_grace_seconds`) ->
       `{:skip, slot, :missed, missed_count}`
    3. project missing, archived or paused -> `{:skip, slot, :project_paused, nil}`
    4. `overlap: "skip"` and the previous fire's task is still `open`, `ready` or
       `in_progress` -> `{:skip, slot, :overlap, nil}`
    5. `daily_remaining == 0` -> `{:skip, slot, :daily_cap, nil}`
    6. otherwise `{:fire, slot}`

  A stored spec that no longer parses is `{:error, {:invalid_schedule_spec, ...}}`
  (the ticker counts it; it is never silently treated as "nothing due").
  `missed_count` is the number of slots in `(after, now]`, including the latest.

  `misfired?/3` and `accounted_for?/2` are public because boot recovery
  (`Schedule.Ticker`) applies the same two rules to the slot of a recorded intent: one
  predicate for "too late to fire", no second copy.
  """

  alias ForemanServer.Schedule.Spec

  @type ctx :: %{
          project: map() | nil,
          last_task: map() | nil,
          daily_remaining: non_neg_integer() | :unlimited
        }

  @type decision ::
          {:fire, integer()}
          | {:skip, integer(), :missed | :project_paused | :overlap | :daily_cap,
             non_neg_integer() | nil}
          | :wait
          | {:error, Spec.parse_error()}

  @pending_task_statuses ["open", "ready", "in_progress"]

  @spec plan(map(), DateTime.t(), ctx()) :: decision()
  def plan(schedule, %DateTime{} = now, %{} = ctx) do
    with {:ok, spec} <- Spec.parse(schedule.spec) do
      after_slot = lower_bound(schedule)

      case Spec.latest_slot_at_or_before(spec, now, after_slot) do
        :none -> :wait
        {:ok, slot} -> decide(schedule, spec, slot, after_slot, now, ctx)
      end
    end
  end

  @doc "Slots at or before this unix instant are already accounted for."
  @spec lower_bound(map()) :: integer() | nil
  def lower_bound(schedule) do
    case {schedule.last_slot, schedule.active_since} do
      {nil, since} -> since
      {last, nil} -> last
      {last, since} -> max(last, since)
    end
  end

  @doc """
  Whether `slot` is past the schedule's misfire grace at `now` (rule 2). A schedule
  with no recorded grace has none: any lateness is a miss.
  """
  @spec misfired?(map(), integer(), DateTime.t()) :: boolean()
  def misfired?(schedule, slot, %DateTime{} = now) when is_integer(slot),
    do: DateTime.to_unix(now) - slot > (schedule.misfire_grace_seconds || 0)

  @doc """
  Whether the schedule already accounts for `slot`: a later or equal slot was fired
  or skipped, or the slot falls at or before the baseline (`active_since`: creation,
  last resume or last spec change). Such a slot must never produce a task.
  """
  @spec accounted_for?(map(), integer()) :: boolean()
  def accounted_for?(schedule, slot) when is_integer(slot) do
    case lower_bound(schedule) do
      nil -> false
      bound -> slot <= bound
    end
  end

  defp decide(schedule, spec, slot, after_slot, now, ctx) do
    cond do
      misfired?(schedule, slot, now) ->
        {:skip, slot, :missed, Spec.missed_count(spec, after_slot, now)}

      not project_active?(ctx.project) ->
        {:skip, slot, :project_paused, nil}

      schedule.overlap == "skip" and pending?(ctx.last_task) ->
        {:skip, slot, :overlap, nil}

      ctx.daily_remaining == 0 ->
        {:skip, slot, :daily_cap, nil}

      true ->
        {:fire, slot}
    end
  end

  defp project_active?(nil), do: false
  defp project_active?(%{archived?: true}), do: false
  defp project_active?(%{status: status}) when status in ["paused", "archived"], do: false
  defp project_active?(_), do: true

  defp pending?(%{status: status}), do: status in @pending_task_statuses
  defp pending?(_), do: false
end
