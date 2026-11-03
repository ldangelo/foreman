defmodule ForemanServerWeb.Workspace.ThreadViewTest do
  # The pane's pure view model: how turns become blocks, which blocks are kept, the sidebar's
  # age and the lookup of the selected card.
  use ExUnit.Case, async: true

  alias ForemanServer.Overview
  alias ForemanServer.Overview.ThreadCard
  alias ForemanServer.Threads.Turn
  alias ForemanServerWeb.Workspace.ThreadView
  alias ForemanServerWeb.Workspace.ThreadView.{Block, Log}

  defp turn(seq, role, kind, source, text),
    do: %Turn{seq: seq, role: role, kind: kind, source: source, text: text, at: 1_000 + seq}

  defp out(seq, text, source \\ "stdout"), do: turn(seq, :agent, :text, source, text)
  defp steer(seq, text), do: turn(seq, :operator, :steer, "steer", text)
  defp status(seq, text), do: turn(seq, :system, :status, "run_event", text)
  defp verdict(seq, text), do: turn(seq, :system, :verdict, "review", text)

  defp shape(%Log{blocks: blocks}),
    do: Enum.map(blocks, &{&1.seq, &1.role, &1.kind, &1.source, &1.text, &1.turns})

  describe "log/3: merging output" do
    test "adjacent output lines of one source are one block, their texts joined by a newline" do
      assert %Log{blocks: [block], dropped_turns: 0} =
               ThreadView.log([out(0, "a"), out(1, "b"), out(2, "c")], false)

      assert %Block{
               seq: 0,
               role: :agent,
               kind: :text,
               source: "stdout",
               text: "a\nb\nc",
               turns: 3,
               at: 1_000
             } = block
    end

    test "only the same source merges: stdout, stderr and stdout again are three blocks" do
      log =
        ThreadView.log(
          [out(0, "a"), out(1, "e1", "stderr"), out(2, "e2", "stderr"), out(3, "b")],
          false
        )

      assert shape(log) == [
               {0, :agent, :text, "stdout", "a", 1},
               {1, :agent, :text, "stderr", "e1\ne2", 2},
               {3, :agent, :text, "stdout", "b", 1}
             ]
    end

    test "a steer splits the output around it, and two steers in a row stay two blocks" do
      log =
        ThreadView.log(
          [out(0, "a"), out(1, "b"), steer(2, "go"), steer(3, "again"), out(4, "c")],
          false
        )

      assert shape(log) == [
               {0, :agent, :text, "stdout", "a\nb", 2},
               {2, :operator, :steer, "steer", "go", 1},
               {3, :operator, :steer, "steer", "again", 1},
               {4, :agent, :text, "stdout", "c", 1}
             ]
    end

    test "lifecycle lines and verdicts stand alone and end the output before them" do
      log =
        ThreadView.log(
          [out(0, "a"), status(1, "Run paused"), out(2, "b"), out(3, "c"), verdict(4, "met")],
          true
        )

      assert shape(log) == [
               {0, :agent, :text, "stdout", "a", 1},
               {1, :system, :status, "run_event", "Run paused", 1},
               {2, :agent, :text, "stdout", "b\nc", 2},
               {4, :system, :verdict, "review", "met", 1}
             ]
    end

    test "jobsite output merges per source too, and an empty list is an empty log" do
      log =
        ThreadView.log(
          [
            turn(0, :agent, :text, "jobsite_iteration", "iteration 1"),
            turn(1, :agent, :text, "jobsite_iteration", "iteration 2"),
            turn(2, :agent, :text, "jobsite_output", "result")
          ],
          true
        )

      assert Enum.map(log.blocks, &{&1.source, &1.text}) == [
               {"jobsite_iteration", "iteration 1\niteration 2"},
               {"jobsite_output", "result"}
             ]

      assert %Log{blocks: [], dropped_turns: 0} = ThreadView.log([], false)
    end

    test "the log says whether the thread is over" do
      assert %Log{terminal?: true} = ThreadView.log([out(0, "a")], true)
      assert %Log{terminal?: false} = ThreadView.log([out(0, "a")], false)
    end
  end

  describe "log/3: the tail" do
    # blocks: A (2 turns) B (1) C (3) D (1) E (1)
    defp five_blocks do
      [
        out(0, "a1"),
        out(1, "a2"),
        steer(2, "b"),
        out(3, "c1"),
        out(4, "c2"),
        out(5, "c3"),
        steer(6, "d"),
        out(7, "e")
      ]
    end

    test "keeps the newest blocks and counts the TURNS of the blocks it leaves out" do
      log = ThreadView.log(five_blocks(), false, 2)

      assert Enum.map(log.blocks, & &1.seq) == [6, 7]
      # A (2) + B (1) + C (3): turns, not blocks
      assert log.dropped_turns == 6
    end

    test "nothing is dropped while the blocks fit" do
      log = ThreadView.log(five_blocks(), false, 5)
      assert length(log.blocks) == 5
      assert log.dropped_turns == 0

      assert %Log{dropped_turns: 0} = ThreadView.log(five_blocks(), false, 50)
    end

    test "a block that lost its first lines to the limit is dropped whole, never cut" do
      log = ThreadView.log(five_blocks(), false, 3)
      assert Enum.map(log.blocks, & &1.seq) == [3, 6, 7]
      assert hd(log.blocks).text == "c1\nc2\nc3"
      assert log.dropped_turns == 3
    end

    test "the default is the newest 100 blocks" do
      turns = for seq <- 0..129, do: steer(seq, "m#{seq}")
      log = ThreadView.log(turns, false)

      assert ThreadView.tail() == 100
      assert length(log.blocks) == 100
      assert hd(log.blocks).seq == 30
      assert log.dropped_turns == 30
    end
  end

  describe "age/2" do
    @now 1_800_000_000_000

    test "a thread without a time has no age" do
      assert ThreadView.age(nil, @now) == nil
    end

    test "is now under a minute, then minutes, hours and days, rounded down" do
      for {elapsed_ms, shown} <- [
            {0, "now"},
            {59_999, "now"},
            {60_000, "1m"},
            {5 * 60_000, "5m"},
            {59 * 60_000 + 59_999, "59m"},
            {3_600_000, "1h"},
            {3 * 3_600_000 + 1_000, "3h"},
            {23 * 3_600_000 + 3_599_999, "23h"},
            {86_400_000, "1d"},
            {2 * 86_400_000 + 5, "2d"},
            {40 * 86_400_000, "40d"}
          ] do
        assert ThreadView.age(@now - elapsed_ms, @now) == shown, "#{elapsed_ms} ms"
      end
    end

    test "a time ahead of the clock reads now, never a negative age" do
      assert ThreadView.age(@now + 90_000, @now) == "now"
    end
  end

  describe "find_card/2" do
    defp card(thread_id, group),
      do: %ThreadCard{thread_id: thread_id, group: group, reason: :no_pr, title: thread_id}

    defp overview(groups) do
      %Overview{
        project_id: "p",
        groups: Map.merge(Map.new(ForemanServer.Overview.Group.all(), &{&1, []}), groups),
        counts: %{},
        attention: %{needed: false, count: 0, reasons: []},
        truncated: false,
        tabs: %{},
        generated_at: 0
      }
    end

    test "finds the card in whichever group holds it" do
      overview =
        overview(%{
          working: [card("run:w1", :working)],
          resolved: [card("run:r1", :resolved), card("jobsite:j1", :resolved)]
        })

      assert %ThreadCard{thread_id: "run:w1"} = ThreadView.find_card(overview, "run:w1")
      assert %ThreadCard{thread_id: "jobsite:j1"} = ThreadView.find_card(overview, "jobsite:j1")
    end

    test "an id that is not one of the project's cards is nil, whatever it looks like" do
      overview = overview(%{working: [card("run:w1", :working)]})

      for id <- ["run:other-project", "run:W1", "w1", "", "run:w1 ", "jobsite:w1", "../run:w1"] do
        assert ThreadView.find_card(overview, id) == nil, inspect(id)
      end
    end
  end
end
