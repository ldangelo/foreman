defmodule ForemanServer.Overview.PrRollupTest do
  @moduledoc """
  `PrFold.rollup/2`: the one PR view a thread is classified by when its head run opened a PR in
  several repositories (foreman-w0tnj). Pure.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ForemanServer.Overview.PrFold

  defp view(state, gate \\ :none, updated \\ nil, extra \\ %{}) do
    PrFold.default_entry()
    |> Map.merge(%{run_id: "r", failure_reason: nil, pr_state: state, merge_gate: gate})
    |> Map.merge(%{pr_updated_at: updated})
    |> Map.merge(extra)
  end

  defp rolled(primary, others) do
    %{pr_state: state, merge_gate: gate, pr_updated_at: updated} = PrFold.rollup(primary, others)
    {state, gate, updated}
  end

  describe "a run with a single PR reads exactly what it read before" do
    test "the primary's view is returned untouched, whatever its state" do
      for state <- [nil, :open, :conflicted, :merged, :closed],
          gate <- [:none, :pending, :approved] do
        primary = view(state, gate, 5, %{pr_url: "https://g/p/1", head_sha: "s"})
        assert PrFold.rollup(primary, []) == primary
      end
    end

    test "no view stays no view, with or without other PRs" do
      assert PrFold.rollup(nil, []) == nil
      assert PrFold.rollup(nil, [view(:open)]) == nil
    end
  end

  describe "pr_state over several PRs" do
    @states [
      # a live PR keeps the thread open, whatever the others did
      {[:merged, :open], :open},
      {[:open, :merged], :open},
      {[:closed, :open], :open},
      {[:open, :open], :open},
      {[:merged, :merged, :open], :open},
      # conflicted outranks open
      {[:merged, :conflicted], :conflicted},
      {[:open, :conflicted], :conflicted},
      {[:conflicted, :open], :conflicted},
      {[:conflicted, :conflicted], :conflicted},
      # nothing live: merged when any merged, else closed
      {[:merged, :merged], :merged},
      {[:merged, :closed], :merged},
      {[:closed, :merged], :merged},
      {[:closed, :closed], :closed},
      # a PR without a state is not live and not terminal
      {[:merged, nil], :merged},
      {[nil, :closed], :closed},
      {[nil, :open], :open},
      {[nil, nil], nil}
    ]

    for {[primary | others], expected} <- @states do
      test "#{inspect([primary | others])} -> #{inspect(expected)}" do
        primary = view(unquote(primary))
        others = Enum.map(unquote(others), &view/1)
        assert {unquote(expected), _gate, _updated} = rolled(primary, others)
      end
    end
  end

  describe "merge_gate" do
    test "is read over the LIVE PRs: a merged PR's approval says nothing about the open one" do
      assert {:open, :pending, _} = rolled(view(:merged, :approved), [view(:open, :pending)])
      assert {:open, :none, _} = rolled(view(:merged, :approved), [view(:open, :none)])
    end

    test "the strongest live gate wins: approved, then pending, then none" do
      assert {_, :approved, _} = rolled(view(:open, :pending), [view(:open, :approved)])
      assert {_, :approved, _} = rolled(view(:open, :approved), [view(:open, :pending)])
      assert {_, :pending, _} = rolled(view(:open, :none), [view(:open, :pending)])
      assert {_, :none, _} = rolled(view(:open, :none), [view(:open, :none)])
    end

    test "a conflicted PR counts as live for the gate" do
      assert {:conflicted, :approved, _} =
               rolled(view(:conflicted, :approved), [view(:merged, :pending)])
    end

    test "with nothing live the strongest gate of all PRs is kept" do
      assert {:merged, :approved, _} = rolled(view(:merged, :approved), [view(:closed, :pending)])
      assert {:merged, :pending, _} = rolled(view(:merged, :none), [view(:merged, :pending)])
      assert {:closed, :none, _} = rolled(view(:closed), [view(:closed)])
    end
  end

  describe "pr_updated_at" do
    test "is the newest observation of any PR" do
      assert {_, _, 9} = rolled(view(:merged, :none, 3), [view(:merged, :none, 9)])
      assert {_, _, 9} = rolled(view(:merged, :none, 9), [view(:open, :none, 3)])
    end

    test "ignores PRs never observed; nil when none was" do
      assert {_, _, 4} = rolled(view(:open, :none, nil), [view(:open, :none, 4)])
      assert {_, _, nil} = rolled(view(:open), [view(:open)])
    end
  end

  test "every other field is the primary's: the roll-up only changes the three it names" do
    primary =
      view(:merged, :approved, 1, %{
        run_id: "run-1",
        pr_url: "https://g/a/1",
        pr_number: 1,
        head_sha: "sha-a",
        base_branch: "main",
        failure_reason: "boom",
        merge_gate_at: 77
      })

    other = view(:open, :pending, 2, %{pr_url: "https://g/b/2", pr_number: 2, head_sha: "sha-b"})
    rolled = PrFold.rollup(primary, [other])

    assert Map.drop(rolled, [:pr_state, :merge_gate, :pr_updated_at]) ==
             Map.drop(primary, [:pr_state, :merge_gate, :pr_updated_at])

    assert %{pr_state: :open, merge_gate: :pending, pr_updated_at: 2} = rolled
  end

  describe "properties" do
    defp pr_view do
      gen all(
            state <- StreamData.member_of([nil, :open, :conflicted, :merged, :closed]),
            gate <- StreamData.member_of([:none, :pending, :approved]),
            updated <- StreamData.one_of([StreamData.constant(nil), StreamData.integer(0..100)])
          ) do
        view(state, gate, updated)
      end
    end

    property "the roll-up is live exactly when some PR is live, and never merged while one is" do
      check all(
              primary <- pr_view(),
              others <- StreamData.list_of(pr_view(), min_length: 1, max_length: 3)
            ) do
        prs = [primary | others]
        any_live? = Enum.any?(prs, &(&1.pr_state in [:open, :conflicted]))
        {state, gate, updated} = rolled(primary, others)

        assert state in [:open, :conflicted] == any_live?
        assert gate in [:none, :pending, :approved]
        if any_live?, do: refute(state in [:merged, :closed])

        if not any_live? and Enum.any?(prs, &(&1.pr_state == :merged)),
          do: assert(state == :merged)

        assert updated ==
                 prs
                 |> Enum.map(& &1.pr_updated_at)
                 |> Enum.filter(&is_integer/1)
                 |> Enum.max(fn -> nil end)
      end
    end

    property "the roll-up does not depend on the order of the other repositories' PRs" do
      check all(
              primary <- pr_view(),
              others <- StreamData.list_of(pr_view(), min_length: 1, max_length: 4)
            ) do
        assert rolled(primary, others) == rolled(primary, Enum.reverse(others))
      end
    end
  end
end
