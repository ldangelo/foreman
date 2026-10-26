defmodule ForemanServer.Schedule.PlannerTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Schedule.Planner

  defp dt(iso) do
    {:ok, dt, 0} = DateTime.from_iso8601(iso)
    dt
  end

  defp unix(iso), do: iso |> dt() |> DateTime.to_unix()

  defp schedule(overrides \\ %{}) do
    Map.merge(
      %{
        spec: %{"every" => "1h", "timezone" => "UTC", "anchor" => "2026-01-01T00:00:00Z"},
        status: "active",
        overlap: "skip",
        misfire_grace_seconds: 600,
        active_since: unix("2026-01-01T00:00:00Z"),
        last_slot: unix("2026-01-01T00:00:00Z"),
        last_task_id: nil
      },
      overrides
    )
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{project: %{status: "active"}, last_task: nil, daily_remaining: :unlimited},
      overrides
    )
  end

  defp plan(now, schedule \\ schedule(), ctx \\ ctx()), do: Planner.plan(schedule, dt(now), ctx)

  test "nothing due waits; a due slot inside grace fires" do
    assert :wait = plan("2026-01-01T00:30:00Z")
    assert {:fire, slot} = plan("2026-01-01T01:00:05Z")
    assert slot == unix("2026-01-01T01:00:00Z")
  end

  test "downtime yields ONE decision for the latest slot, never one per missed slot" do
    assert {:fire, slot} = plan("2026-01-01T05:00:10Z")
    assert slot == unix("2026-01-01T05:00:00Z")
  end

  test "past the misfire grace the slot is skipped as missed with the exact slot count" do
    # Slots 01:00, 02:00, 03:00, 04:00, 05:00 were due and none fired.
    assert {:skip, slot, :missed, 5} = plan("2026-01-01T05:20:00Z")
    assert slot == unix("2026-01-01T05:00:00Z")
  end

  test "grace boundary: exactly grace seconds late still fires" do
    assert {:fire, _} = plan("2026-01-01T01:10:00Z")
    assert {:skip, _, :missed, 1} = plan("2026-01-01T01:10:01Z")
  end

  test "precedence: missed beats paused beats overlap beats cap" do
    everything =
      ctx(%{
        project: %{status: "paused"},
        last_task: %{status: "in_progress"},
        daily_remaining: 0
      })

    late = "2026-01-01T05:20:00Z"
    on_time = "2026-01-01T05:00:05Z"

    assert {:skip, _, :missed, _} = plan(late, schedule(), everything)
    assert {:skip, _, :project_paused, nil} = plan(on_time, schedule(), everything)

    no_pause = %{everything | project: %{status: "active"}}
    assert {:skip, _, :overlap, nil} = plan(on_time, schedule(), no_pause)

    assert {:skip, _, :daily_cap, nil} = plan(on_time, schedule(), %{no_pause | last_task: nil})
  end

  test "project missing or archived is treated as paused" do
    assert {:skip, _, :project_paused, nil} =
             plan("2026-01-01T01:00:05Z", schedule(), ctx(%{project: nil}))

    assert {:skip, _, :project_paused, nil} =
             plan(
               "2026-01-01T01:00:05Z",
               schedule(),
               ctx(%{project: %{status: "active", archived?: true}})
             )
  end

  test "overlap: skip only blocks while the previous task is pending" do
    now = "2026-01-01T01:00:05Z"

    for status <- ~w(open ready in_progress) do
      assert {:skip, _, :overlap, nil} =
               plan(now, schedule(), ctx(%{last_task: %{status: status}}))
    end

    for status <- ~w(closed failed) do
      assert {:fire, _} = plan(now, schedule(), ctx(%{last_task: %{status: status}}))
    end

    assert {:fire, _} =
             plan(now, schedule(%{overlap: "allow"}), ctx(%{last_task: %{status: "in_progress"}}))
  end

  test "daily cap: zero remaining skips, any remaining or unlimited fires" do
    now = "2026-01-01T01:00:05Z"
    assert {:skip, _, :daily_cap, nil} = plan(now, schedule(), ctx(%{daily_remaining: 0}))
    assert {:fire, _} = plan(now, schedule(), ctx(%{daily_remaining: 1}))
    assert {:fire, _} = plan(now, schedule(), ctx(%{daily_remaining: :unlimited}))
  end

  test "slots at or before active_since never count (resume/creation baseline)" do
    resumed =
      schedule(%{
        last_slot: unix("2026-01-01T00:00:00Z"),
        active_since: unix("2026-01-03T10:30:00Z")
      })

    assert :wait = plan("2026-01-03T10:45:00Z", resumed)
    assert {:fire, slot} = plan("2026-01-03T11:00:05Z", resumed)
    assert slot == unix("2026-01-03T11:00:00Z")
  end

  test "weekday cron waits over the weekend after a Friday fire" do
    cron =
      schedule(%{
        spec: %{"cron" => "0 9 * * 1-5", "timezone" => "UTC"},
        last_slot: unix("2026-01-02T09:00:00Z")
      })

    assert :wait = plan("2026-01-03T12:00:00Z", cron)
    assert :wait = plan("2026-01-04T12:00:00Z", cron)
    assert {:fire, slot} = plan("2026-01-05T09:00:30Z", cron)
    assert slot == unix("2026-01-05T09:00:00Z")
  end

  test "an unparseable stored spec is an explicit error, not silence" do
    assert {:error, {:invalid_schedule_spec, :every, :invalid_format}} =
             plan("2026-01-01T01:00:05Z", schedule(%{spec: %{"every" => "nonsense"}}))
  end

  test "a stored interval beyond today's cap is an explicit error, not a crash" do
    spec = %{"every" => "3000000d", "timezone" => "UTC", "anchor" => "2026-01-01T00:00:00Z"}

    assert {:error, {:invalid_schedule_spec, :every, :above_maximum}} =
             plan("2026-01-01T01:00:05Z", schedule(%{spec: spec}))
  end

  test "misfired?/3 is rule 2 of plan/3: late means strictly more than the grace" do
    on_time = "2026-01-01T01:10:00Z"
    late = "2026-01-01T01:10:01Z"
    slot = unix("2026-01-01T01:00:00Z")

    refute Planner.misfired?(schedule(), slot, dt(on_time))
    assert Planner.misfired?(schedule(), slot, dt(late))

    # plan/3 and the shared predicate agree on both sides of the boundary.
    assert {:fire, ^slot} = plan(on_time)
    assert {:skip, ^slot, :missed, _count} = plan(late)

    # A schedule with no recorded grace has none.
    no_grace = schedule(%{misfire_grace_seconds: nil})
    refute Planner.misfired?(no_grace, slot, dt("2026-01-01T01:00:00Z"))
    assert Planner.misfired?(no_grace, slot, dt("2026-01-01T01:00:01Z"))
  end

  test "accounted_for?/2: slots at or before max(last_slot, active_since) never produce a task" do
    fired =
      schedule(%{
        last_slot: unix("2026-01-01T05:00:00Z"),
        active_since: unix("2026-01-01T03:30:00Z")
      })

    assert Planner.accounted_for?(fired, unix("2026-01-01T05:00:00Z"))
    assert Planner.accounted_for?(fired, unix("2026-01-01T04:00:00Z"))
    refute Planner.accounted_for?(fired, unix("2026-01-01T06:00:00Z"))

    # A baseline later than the last fire (a resume or a spec change) decides instead.
    resumed =
      schedule(%{
        last_slot: unix("2026-01-01T00:00:00Z"),
        active_since: unix("2026-01-03T10:30:00Z")
      })

    assert Planner.accounted_for?(resumed, unix("2026-01-03T10:00:00Z"))
    refute Planner.accounted_for?(resumed, unix("2026-01-03T11:00:00Z"))

    # Nothing recorded yet: nothing is accounted for.
    refute Planner.accounted_for?(schedule(%{last_slot: nil, active_since: nil}), 0)
  end
end
