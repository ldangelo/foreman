defmodule ForemanServer.Threads.TranscriptBuildTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Threads.Transcript
  alias ForemanServer.Threads.Turn

  defp line(channel, content, at), do: %{channel: channel, content: content, at: at}

  defp texts(%{turns: turns}), do: Enum.map(turns, &{&1.role, &1.kind, &1.source, &1.text})

  test "empty inputs yield no turns and no truncation" do
    assert %{turns: [], truncated: false, omitted_entries: 0} = Transcript.build_turns(%{})
  end

  test "five consecutive stdout lines in one phase collapse to one agent turn" do
    entries = for n <- 1..5, do: line("stdout", "line #{n}", 1_000 + n)

    built =
      Transcript.build_turns(%{
        log_entries: entries,
        phases: [%{index: 1, started_at: 500, ended_at: 9_000}]
      })

    assert [%Turn{seq: 0, role: :agent, kind: :text, source: "stdout", at: 1_001} = turn] =
             built.turns

    assert turn.text == "line 1\nline 2\nline 3\nline 4\nline 5"
  end

  test "stdout, stderr, stdout stay three turns and stderr keeps its source" do
    built =
      Transcript.build_turns(%{
        log_entries: [
          line("stdout", "a", 1_000),
          line("stderr", "boom", 1_001),
          line("stdout", "b", 1_002)
        ]
      })

    assert texts(built) == [
             {:agent, :text, "stdout", "a"},
             {:agent, :text, "stderr", "boom"},
             {:agent, :text, "stdout", "b"}
           ]

    assert Enum.map(built.turns, & &1.seq) == [0, 1, 2]
  end

  test "a phase boundary and a time gap each split an otherwise contiguous run of lines" do
    phases = [
      %{index: 1, started_at: 0, ended_at: 1_500},
      %{index: 2, started_at: 1_600, ended_at: nil}
    ]

    built =
      Transcript.build_turns(%{
        log_entries: [
          line("stdout", "p1", 1_000),
          line("stdout", "p2a", 1_700),
          line("stdout", "p2b", 1_800),
          line("stdout", "p2-late", 1_800 + 5_001)
        ],
        phases: phases,
        gap_ms: 5_000
      })

    assert Enum.map(built.turns, & &1.text) == ["p1", "p2a\np2b", "p2-late"]
  end

  test "a steer queued between two phases is an operator turn at the right position" do
    built =
      Transcript.build_turns(%{
        log_entries: [line("stdout", "phase one", 1_000), line("stdout", "phase two", 3_000)],
        phases: [
          %{index: 1, started_at: 0, ended_at: 1_500},
          %{index: 2, started_at: 2_500, ended_at: nil}
        ],
        steer: [%{at: 2_000, text: "use the other approach"}],
        run_events: [
          %{event_type: "RunPaused", at: 2_100, reason: "steer"},
          %{event_type: "RunResumed", at: 2_200, reason: nil},
          %{event_type: "WorkerHeartbeat", at: 2_300, reason: nil}
        ]
      })

    assert texts(built) == [
             {:agent, :text, "stdout", "phase one"},
             {:operator, :steer, "steer", "use the other approach"},
             {:system, :status, "run_event", "Run paused: steer"},
             {:system, :status, "run_event", "Run resumed"},
             {:agent, :text, "stdout", "phase two"}
           ]
  end

  test "a steer inside a stretch of stdout splits it instead of reordering around it" do
    built =
      Transcript.build_turns(%{
        log_entries: [line("stdout", "before", 1_000), line("stdout", "after", 3_000)],
        steer: [%{at: 2_000, text: "hey"}]
      })

    assert Enum.map(built.turns, & &1.text) == ["before", "hey", "after"]
  end

  test "identical timestamps are ordered by source rank then arrival, identically every run" do
    inputs = %{
      log_entries: [line("stdout", "out", 5_000)],
      steer: [%{at: 5_000, text: "steer"}],
      run_events: [%{event_type: "RunCompleted", at: 5_000, reason: nil}],
      review: %{verdict: "met", summary: "fine", at: 5_000}
    }

    first = Transcript.build_turns(inputs)
    second = Transcript.build_turns(inputs)

    assert first == second

    assert Enum.map(first.turns, &{&1.seq, &1.kind}) ==
             [{0, :steer}, {1, :status}, {2, :text}, {3, :verdict}]
  end

  test "omitted entries mark the result truncated with the count" do
    built = Transcript.build_turns(%{log_entries: [line("stdout", "x", 1)], omitted_entries: 12})

    assert %{truncated: true, omitted_entries: 12} = built
    assert length(built.turns) == 1
  end

  test "a truncated jobsite iteration text marks the result truncated" do
    built =
      Transcript.build_turns(%{
        door: :jobsite,
        jobsite_iterations: [
          %{index: 1, status: "completed", text: "tail", text_truncated?: true, message: nil},
          %{index: 2, status: "failed", text: nil, text_truncated?: false, message: "crash"}
        ]
      })

    assert built.truncated
    assert built.omitted_entries == 0

    assert texts(built) == [
             {:agent, :text, "jobsite_iteration", "tail"},
             {:system, :status, "jobsite_iteration", "Iteration 2 failed: crash"}
           ]

    assert Enum.all?(built.turns, &is_nil(&1.at))
  end

  test "the trailing agent turn is withheld while it can still grow, so seq never shifts" do
    base = %{
      log_entries: [line("stdout", "a", 1_000), line("stdout", "b", 1_100)],
      terminal?: false,
      gap_ms: 1_000
    }

    # still within the gap: the turn may yet absorb the next line
    assert %{turns: []} = Transcript.build_turns(Map.put(base, :now_ms, 1_500))

    # gap elapsed: any later line starts a new turn, so this one is final
    assert %{turns: [%Turn{text: "a\nb"}]} = Transcript.build_turns(Map.put(base, :now_ms, 2_200))

    # terminal threads are always final
    assert %{turns: [%Turn{text: "a\nb"}]} =
             Transcript.build_turns(%{base | terminal?: true})
  end
end
