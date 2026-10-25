defmodule ForemanServer.Usage.CoordinatorRollupTest do
  @moduledoc """
  A coordinator turn belongs to no thread: its usage record (`thread_id: nil`) is
  counted in the project total and in the day, model, provider and role
  breakdowns, but never in `by_thread`, so the thread count, the thread rows and
  the cache hints stay thread-only. A workflow record for a real run still lands
  there.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Usage
  alias ForemanServer.Usage.{Ledger, Rollup}

  defp workflow(overrides \\ []) do
    Map.merge(
      %{
        thread_kind: "workflow",
        thread_id: "run-1",
        role: "thread",
        model: "m1",
        provider: "claude",
        at: "2026-01-01T10:00:00Z",
        usage: %Usage{input_tokens: 10, output_tokens: 5, total_tokens: 15, cost_usd: 0.01}
      },
      Map.new(overrides)
    )
  end

  defp coordinator(overrides \\ []) do
    Map.merge(
      %{
        thread_kind: "coordinator",
        thread_id: nil,
        role: "coordinator",
        model: "m1",
        provider: "pi",
        at: "2026-01-01T11:00:00Z",
        usage: %Usage{input_tokens: 100, output_tokens: 20, total_tokens: 120, cost_usd: nil}
      },
      Map.new(overrides)
    )
  end

  test "a coordinator record counts everywhere but by_thread; a workflow one still lands there" do
    rollup = Rollup.from_records([workflow(), coordinator()])

    assert %{events: 2, cost_unknown_events: 1, usage: %Usage{total_tokens: 135}} = rollup.total
    assert rollup.total.usage.cost_usd == 0.01
    assert %{events: 2} = rollup.by_day["2026-01-01"]
    assert %{events: 2} = rollup.by_model["m1"]
    assert %{events: 1, usage: %Usage{total_tokens: 15}} = rollup.by_provider["claude"]
    assert %{events: 1, usage: %Usage{total_tokens: 120}} = rollup.by_provider["pi"]
    assert %{events: 1, usage: %Usage{total_tokens: 120}} = rollup.by_role["coordinator"]
    assert %{events: 1, usage: %Usage{total_tokens: 15}} = rollup.by_role["thread"]

    assert Map.keys(rollup.by_thread) == ["run-1"]
    assert %{bucket: %{events: 1, usage: %Usage{total_tokens: 15}}} = rollup.by_thread["run-1"]
  end

  test "coordinator usage alone leaves no thread row, and its cost stays unknown, never 0.0" do
    rollup = Rollup.from_records([coordinator(), coordinator(at: "2026-01-01T12:00:00Z")])

    assert rollup.by_thread == %{}
    assert %{events: 2, cost_unknown_events: 2} = rollup.total
    assert %Usage{total_tokens: 240, cost_usd: nil} = rollup.total.usage
    assert %{events: 2} = rollup.by_role["coordinator"]
  end

  describe "Ledger" do
    test "a turn key replaces instead of double counting; another turn adds" do
      key = {"coordinator", "proj", {:turn, "m1:a1"}}
      ledger = Ledger.new() |> Ledger.put(key, coordinator()) |> Ledger.put(key, coordinator())
      assert Ledger.rollup(ledger, nil, nil).total.events == 1

      ledger = Ledger.put(ledger, {"coordinator", "proj", {:turn, "m2:a1"}}, coordinator())
      rollup = Ledger.rollup(ledger, nil, nil)
      assert rollup.total.events == 2
      assert rollup.by_thread == %{}
    end

    test "records of both kinds roll up together, and from/to select whole days" do
      work_key = {"workflow", "run-1", {:worker, "w1"}}
      turn_key = {"coordinator", "proj", {:turn, "t1"}}

      ledger =
        Ledger.new()
        |> Ledger.put(work_key, workflow(at: "2026-01-01T10:00:00Z"))
        |> Ledger.put(turn_key, coordinator(at: "2026-01-02T10:00:00Z"))

      assert Ledger.rollup(ledger, nil, nil).total.events == 2

      first_day = Ledger.rollup(ledger, nil, "2026-01-01")
      assert first_day.total.events == 1
      assert Map.keys(first_day.by_thread) == ["run-1"]

      second_day = Ledger.rollup(ledger, "2026-01-02", nil)
      assert second_day.total.events == 1
      assert second_day.by_thread == %{}
      assert Map.keys(second_day.by_role) == ["coordinator"]
    end

    test "a coordinator record past the retention window leaves the days, not the total" do
      old_key = {"coordinator", "proj", {:turn, "old"}}
      new_key = {"workflow", "run-1", {:worker, "w1"}}

      ledger =
        Ledger.new()
        |> Ledger.put(old_key, coordinator(at: "2025-01-01T00:00:00Z"))
        |> Ledger.put(new_key, workflow(at: "2026-02-10T00:00:00Z"))

      rollup = Ledger.rollup(ledger, nil, nil)
      assert rollup.total.events == 2
      assert Map.keys(rollup.by_day) == ["2026-02-10"]
      assert Map.keys(rollup.by_thread) == ["run-1"]
      assert Ledger.rollup(ledger, "2025-01-01", nil).total.events == 1
    end
  end
end
