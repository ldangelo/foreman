defmodule ForemanServer.Usage.RollupTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Usage
  alias ForemanServer.Usage.{Ledger, Rollup}

  defp record(overrides) do
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

  defp unpriced(tokens),
    do: %Usage{input_tokens: tokens, output_tokens: 0, total_tokens: tokens, cost_usd: nil}

  test "events on the same thread sum tokens and cost" do
    rollup =
      Rollup.from_records([record([]), record(at: "2026-01-01T11:00:00Z")])

    assert %{total: %{usage: %{total_tokens: 30, cost_usd: cost}, events: 2}} = rollup
    assert_in_delta cost, 0.02, 1.0e-9

    assert [%{bucket: %{events: 2}, last_at: "2026-01-01T11:00:00Z"}] =
             Map.values(rollup.by_thread)
  end

  test "an event without cost is counted as unknown, never as 0.0" do
    rollup = Rollup.from_records([record([]), record(usage: unpriced(7))])

    assert %{total: %{usage: %{cost_usd: 0.01}, cost_unknown_events: 1, events: 2}} = rollup

    only_unknown = Rollup.from_records([record(usage: unpriced(7))])
    assert only_unknown.total.usage.cost_usd == nil
    assert only_unknown.total.cost_unknown_events == 1
  end

  test "UTC day boundaries split by_day buckets" do
    rollup =
      Rollup.from_records([
        record(at: "2026-01-01T23:59:59Z"),
        record(at: "2026-01-02T00:00:00Z")
      ])

    assert Map.keys(rollup.by_day) |> Enum.sort() == ["2026-01-01", "2026-01-02"]
  end

  test "nil model and provider fall into the reserved unknown bucket" do
    rollup = Rollup.from_records([record(model: nil, provider: nil)])
    assert Map.keys(rollup.by_model) == ["unknown"]
    assert Map.keys(rollup.by_provider) == ["unknown"]
  end

  test "roles are split" do
    rollup = Rollup.from_records([record([]), record(role: "coordinator", thread_id: "c1")])
    assert rollup.by_role |> Map.keys() |> Enum.sort() == ["coordinator", "thread"]
  end

  test "a day older than 366 days before the newest is pruned from by_day but kept in total" do
    rollup =
      Rollup.from_records([
        record(at: "2025-01-01T00:00:00Z"),
        record(at: "2026-02-10T00:00:00Z")
      ])

    assert Map.keys(rollup.by_day) == ["2026-02-10"]
    assert rollup.total.events == 2
  end

  test "thread keeps only the most recent events, oldest first dropped" do
    records = for h <- 1..7, do: record(at: "2026-01-01T0#{h}:00:00Z")
    [thread] = Rollup.from_records(records).by_thread |> Map.values()
    assert length(thread.recent) == Rollup.recent_window()
    assert hd(thread.recent).at == "2026-01-01T03:00:00Z"
  end

  describe "Ledger" do
    test "same key replaces instead of double counting" do
      key = {"workflow", "run-1", {:worker, "w1"}}
      ledger = Ledger.new() |> Ledger.put(key, record([])) |> Ledger.put(key, record([]))
      assert Ledger.rollup(ledger, nil, nil).total.events == 1
    end

    test "from/to select whole days" do
      ledger =
        Ledger.new()
        |> Ledger.put(
          {"workflow", "a", {:worker, "w"}},
          record(at: "2026-01-01T10:00:00Z", thread_id: "a")
        )
        |> Ledger.put(
          {"workflow", "b", {:worker, "w"}},
          record(at: "2026-01-03T10:00:00Z", thread_id: "b")
        )

      assert Ledger.rollup(ledger, "2026-01-02", nil).total.events == 1
      assert Ledger.rollup(ledger, nil, "2026-01-01").total.events == 1
      assert Ledger.rollup(ledger, nil, nil).total.events == 2
    end

    test "pruned days stay in the unfiltered total only" do
      ledger =
        Ledger.new()
        |> Ledger.put(
          {"workflow", "old", {:worker, "w"}},
          record(at: "2025-01-01T00:00:00Z", thread_id: "old")
        )
        |> Ledger.put(
          {"workflow", "new", {:worker, "w"}},
          record(at: "2026-02-10T00:00:00Z", thread_id: "new")
        )

      assert Ledger.rollup(ledger, nil, nil).total.events == 2
      assert Ledger.rollup(ledger, "2025-01-01", nil).total.events == 1
    end

    test "worker usage of a jobsite supersedes its iteration usage in either order" do
      worker = {"jobsite", "j1", {:worker, "w1"}}
      iter = {"jobsite", "j1", {:iteration, 1}}
      rec = record(thread_kind: "jobsite", thread_id: "j1")

      a = Ledger.new() |> Ledger.put(iter, rec) |> Ledger.put(worker, rec)
      b = Ledger.new() |> Ledger.put(worker, rec) |> Ledger.put(iter, rec)

      assert Ledger.rollup(a, nil, nil).total.events == 1
      assert Ledger.rollup(b, nil, nil).total.events == 1
    end
  end
end
