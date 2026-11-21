defmodule ForemanServer.ProjectLimits do
  @moduledoc """
  Typed `limits` block of the project read model: the configured limits, current
  usage, and when a daily cap resets. Pure over the numbers
  `ForemanServer.ProjectionStore.project_limits/2` gathers.

  `max_concurrent_runs` is the project's own limit: its `max_concurrent_runs`
  setting, else the per-project default. No global value clamps it. `running_runs`
  and `waiting_runs` count the project's slot holders and queued waiters;
  `active_runs` keeps counting project reservations (which include paused runs).

  `deferred_tasks` counts the project's tasks that were dispatched
  (`TaskDispatched`: status `"in_progress"`, run id assigned) but whose run
  never started because run admission refused them (paused, daily cap, run
  limit) or queued them for a slot. `Workflow.Dispatcher` re-admits them when the
  project resumes, its settings change, a finished run frees its reservation, or
  the UTC day rolls over (`resets_at/1`: the daily cap clears then).
  """

  alias ForemanServer.ProjectSettings
  alias ForemanServer.RunSlots.Config

  @type t :: %{
          max_concurrent_runs: pos_integer(),
          active_runs: non_neg_integer(),
          running_runs: non_neg_integer(),
          waiting_runs: non_neg_integer(),
          daily_thread_cap: pos_integer() | nil,
          threads_started_today: non_neg_integer(),
          remaining_today: non_neg_integer() | nil,
          cap_reached?: boolean(),
          resets_at: String.t(),
          deferred_tasks: non_neg_integer(),
          deferred_today: non_neg_integer(),
          deferred_by_reason: %{String.t() => pos_integer()}
        }

  @type usage :: %{
          active_runs: non_neg_integer(),
          running_runs: non_neg_integer(),
          waiting_runs: non_neg_integer(),
          threads_started_today: non_neg_integer(),
          deferred_tasks: non_neg_integer(),
          deferred_by_reason: %{String.t() => pos_integer()}
        }

  @spec build(map(), usage(), DateTime.t()) :: t()
  def build(project, usage, %DateTime{} = now) when is_map(project) do
    settings = ProjectSettings.from_config(Map.get(project, :config))

    cap = settings.daily_thread_cap
    started = usage.threads_started_today

    %{
      max_concurrent_runs:
        settings.max_concurrent_runs || Config.max_concurrent_runs_per_project(),
      active_runs: usage.active_runs,
      running_runs: usage.running_runs,
      waiting_runs: usage.waiting_runs,
      daily_thread_cap: cap,
      threads_started_today: started,
      remaining_today: cap && max(cap - started, 0),
      cap_reached?: is_integer(cap) and started >= cap,
      resets_at: now |> resets_at() |> DateTime.to_iso8601(),
      deferred_tasks: usage.deferred_tasks,
      deferred_today: usage.deferred_by_reason |> Map.values() |> Enum.sum(),
      deferred_by_reason: usage.deferred_by_reason
    }
  end

  @doc "UTC date string (`Date.to_iso8601/1`) of `now`; the key of the daily counters."
  @spec day(DateTime.t()) :: String.t()
  def day(%DateTime{} = now), do: now |> DateTime.to_date() |> Date.to_iso8601()

  @doc """
  The instant the daily counters reset: the next UTC midnight after `now`. Reported as
  `resets_at` and the moment `Workflow.Dispatcher` re-admits the tasks the cap deferred.
  """
  @spec resets_at(DateTime.t()) :: DateTime.t()
  def resets_at(%DateTime{} = now) do
    now
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end
end
