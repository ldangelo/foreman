defmodule ForemanServer.OverviewCardTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{Overview, ProjectionStore}
  alias ForemanServer.TestSupport.ProjectionStoreReset

  @now 1_000_000_000
  defp opts, do: [now_fun: fn -> @now end]

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp ev(type, payload), do: %{event_type: type, payload: payload}

  defp resolved_run(id, project, n) do
    [
      ev("RunStarted", %{run_id: id, task_id: "t-" <> id, project_id: project}),
      ev("RunCompleted", %{run_id: id, project_id: project}),
      ev("ThreadResolved", %{
        thread_id: "run:" <> id,
        project_id: project,
        reason: "x",
        resolved_by: "op",
        source: "operator",
        at: "2026-10-20T00:00:#{String.pad_leading(Integer.to_string(n), 2, "0")}Z"
      })
    ]
  end

  defp seed do
    events =
      Enum.flat_map(1..30, fn n -> resolved_run("r#{n}", "p", n) end) ++
        [
          ev("RunStarted", %{run_id: "live", task_id: "t-live", project_id: "p"}),
          ev("RunFailed", %{run_id: "other", project_id: "q", reason: "x"})
        ]

    :ok = ProjectionStore.apply_events(events)
  end

  defp resolved_ids(overview), do: Enum.map(overview.groups.resolved, & &1.thread_id)

  test "resolves a resolved thread outside the resolved window, in the group build/2 gives it" do
    seed()
    {:ok, overview} = Overview.build("p", [include_resolved: true] ++ opts())
    assert length(overview.groups.resolved) == 20

    [outside | _] = Enum.map(1..30, &"run:r#{&1}") -- resolved_ids(overview)

    assert {:ok, card} = Overview.card("p", outside, opts())
    assert card.thread_id == outside
    assert card.group == :resolved
    assert card.title != nil
  end

  test "a thread in build/2's groups yields an equal card" do
    seed()
    {:ok, overview} = Overview.build("p", [include_resolved: true] ++ opts())

    for card <- Enum.flat_map(Map.values(overview.groups), & &1) do
      assert {:ok, ^card} = Overview.card("p", card.thread_id, opts())
    end

    assert Enum.any?(overview.groups.working)
  end

  test "another project's, unknown and malformed ids are not found" do
    seed()
    assert {:error, :thread_not_found} = Overview.card("p", "run:other", opts())
    assert {:error, :thread_not_found} = Overview.card("p", "run:nope", opts())
    assert {:error, :thread_not_found} = Overview.card("p", "garbage", opts())
    assert {:error, :thread_not_found} = Overview.card("p", nil, opts())
    assert {:error, :thread_not_found} = Overview.card("p", 42, opts())
  end
end
