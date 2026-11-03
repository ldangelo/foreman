defmodule ForemanServerWeb.Workspace.ThreadViewTest do
  # The pane's pure view model: how chunk turns become blocks, which blocks are kept, the
  # sidebar's age and the lookup of the selected card.
  use ExUnit.Case, async: true

  alias ForemanServer.Overview
  alias ForemanServer.Overview.ThreadCard
  alias ForemanServer.Threads.Turn
  alias ForemanServerWeb.Workspace.ThreadView
  alias ForemanServerWeb.Workspace.ThreadView.{Block, Log}

  # Stored chunks of a real run (run-f43d81536b78f53f51178f6ea6a6f64b, entries 10-15 and 29-36):
  # pi streams a message as output_text_delta chunks, then sends ONE output_text_final chunk
  # holding the whole message again.
  @message_1 "Starting assess. Need discovery report + task description first."
  @deltas_1 ["Star", "ting ass", "ess. Need discovery report", " + task description", " first."]
  @message_2 "READ-ONLY perf analysis. Clear task now. Let me read the code path."
  @deltas_2 [
    "READ",
    "-ONLY per",
    "f analysis.",
    " Cl",
    "ear task now. Let",
    " me read",
    " the code path."
  ]

  defp turn(seq, role, kind, source, text),
    do: %Turn{seq: seq, role: role, kind: kind, source: source, text: text, at: 1_000 + seq}

  defp out(seq, text, source \\ "stdout"), do: turn(seq, :agent, :text, source, text)
  defp steer(seq, text), do: turn(seq, :operator, :steer, "steer", text)
  defp status(seq, text), do: turn(seq, :system, :status, "run_event", text)
  defp verdict(seq, text), do: turn(seq, :system, :verdict, "review", text)

  # One output turn per text, numbered from `from`.
  defp chunks(texts, source \\ "stdout", from \\ 0) do
    texts |> Enum.with_index(from) |> Enum.map(fn {text, seq} -> out(seq, text, source) end)
  end

  defp shape(%Log{blocks: blocks}),
    do: Enum.map(blocks, &{&1.seq, &1.role, &1.kind, &1.source, &1.text, &1.turns})

  describe "log/3: output chunks" do
    test "a streamed message, its deltas and then the whole message once more, is ONE block holding the message" do
      assert %Log{blocks: [block], dropped_turns: 0} =
               ThreadView.log(chunks(@deltas_1 ++ [@message_1], "stdout", 10), false)

      assert %Block{
               seq: 10,
               role: :agent,
               kind: :text,
               source: "stdout",
               text: @message_1,
               turns: 6,
               at: 1_010
             } = block

      assert %Log{blocks: [%Block{seq: 29, text: @message_2, turns: 8}]} =
               ThreadView.log(chunks(@deltas_2 ++ [@message_2], "stdout", 29), true)
    end

    test "the block keeps its seq while the message grows into place" do
      streaming = ThreadView.log(chunks(Enum.take(@deltas_1, 3), "stdout", 10), false)
      finished = ThreadView.log(chunks(@deltas_1 ++ [@message_1], "stdout", 10), false)

      assert [%Block{seq: 10, text: "Starting assess. Need discovery report", turns: 3}] =
               streaming.blocks

      assert [%Block{seq: 10, text: @message_1, turns: 6}] = finished.blocks
    end

    test "deltas that never get a final read as the text they spell, spacing included" do
      assert [%Block{text: @message_2, turns: 7}] =
               ThreadView.log(chunks(@deltas_2), true).blocks
    end

    test "two messages in a row are one block of two paragraphs" do
      turns = chunks(@deltas_1 ++ [@message_1] ++ @deltas_2 ++ [@message_2])

      assert [%Block{seq: 0, turns: 14, text: text}] = ThreadView.log(turns, false).blocks
      assert text == @message_1 <> "\n\n" <> @message_2
    end

    test "stderr chunks end with their own newline and join without a blank line" do
      assert [%Block{source: "stderr", text: "x\ny\n", turns: 2}] =
               ThreadView.log(chunks(["x\n", "y\n"], "stderr"), false).blocks
    end

    test "a chunk repeating the one before it is a message only when it does not end with a newline" do
      assert [%Block{text: "ok\nok\n", turns: 2}] =
               ThreadView.log(chunks(["ok\n", "ok\n"], "stderr"), false).blocks

      assert [%Block{text: "ok", turns: 2}] = ThreadView.log(chunks(["ok", "ok"]), false).blocks
    end

    test "output ahead of a message stays, a blank line apart" do
      assert [%Block{text: "$ ls\na.txt\n\nHi", turns: 4}] =
               ThreadView.log(chunks(["$ ls\n", "a.txt\n", "Hi", "Hi"]), false).blocks
    end

    test "a steer between the deltas and the final prevents the collapse" do
      turns = chunks(["Hel", "lo"]) ++ [steer(2, "go on"), out(3, "Hello")]

      assert shape(ThreadView.log(turns, false)) == [
               {0, :agent, :text, "stdout", "Hello", 2},
               {2, :operator, :steer, "steer", "go on", 1},
               {3, :agent, :text, "stdout", "Hello", 1}
             ]
    end

    test "only the same source runs together: stdout, stderr and stdout again are three blocks" do
      log =
        ThreadView.log(
          [out(0, "a"), out(1, "e1\n", "stderr"), out(2, "e2\n", "stderr"), out(3, "b")],
          false
        )

      assert shape(log) == [
               {0, :agent, :text, "stdout", "a", 1},
               {1, :agent, :text, "stderr", "e1\ne2\n", 2},
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
               {0, :agent, :text, "stdout", "ab", 2},
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
               {2, :agent, :text, "stdout", "bc", 2},
               {4, :system, :verdict, "review", "met", 1}
             ]
    end

    test "a jobsite thread's turns are whole texts: one block each, and an empty list is an empty log" do
      log =
        ThreadView.log(
          [
            turn(0, :agent, :text, "jobsite_iteration", "iteration 1"),
            turn(1, :agent, :text, "jobsite_iteration", "iteration 2"),
            turn(2, :agent, :text, "jobsite_output", "result")
          ],
          true
        )

      assert Enum.map(log.blocks, &{&1.source, &1.text, &1.turns}) == [
               {"jobsite_iteration", "iteration 1", 1},
               {"jobsite_iteration", "iteration 2", 1},
               {"jobsite_output", "result", 1}
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

    test "the turns of a message's collapsed deltas count as turns too" do
      turns = chunks(@deltas_1 ++ [@message_1]) ++ [steer(6, "next"), out(7, "ok")]
      log = ThreadView.log(turns, false, 2)

      assert Enum.map(log.blocks, & &1.seq) == [6, 7]
      assert log.dropped_turns == 6
    end

    test "nothing is dropped while the blocks fit" do
      log = ThreadView.log(five_blocks(), false, 5)
      assert length(log.blocks) == 5
      assert log.dropped_turns == 0

      assert %Log{dropped_turns: 0} = ThreadView.log(five_blocks(), false, 50)
    end

    test "a block that lost its first chunks to the limit is dropped whole, never cut" do
      log = ThreadView.log(five_blocks(), false, 3)
      assert Enum.map(log.blocks, & &1.seq) == [3, 6, 7]
      assert hd(log.blocks).text == "c1c2c3"
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
