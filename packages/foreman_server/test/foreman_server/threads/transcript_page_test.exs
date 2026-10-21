defmodule ForemanServer.Threads.TranscriptPageTest do
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads.Transcript
  alias ForemanServer.Threads.Transcript.Page

  defp uid(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp iso(offset_ms),
    do:
      DateTime.utc_now()
      |> DateTime.add(offset_ms, :millisecond)
      |> DateTime.to_iso8601()

  defp stdout(run_id, seq, line, at),
    do: %{
      event_type: "WorkerStdout",
      payload: %{run_id: run_id, worker_id: "w1", sequence: seq, line: line, timestamp: at}
    }

  defp stderr(run_id, seq, line, at),
    do: %{
      event_type: "WorkerStderr",
      payload: %{run_id: run_id, worker_id: "w1", sequence: seq, line: line, timestamp: at}
    }

  # Durable run-stream events (what `run_events/1` reads): steer + lifecycle.
  defp append_run_events(run_id, events) do
    stream = "run:#{run_id}"

    :ok =
      Store.append_to_stream(
        stream,
        0,
        Enum.map(events, fn {type, data} ->
          %EventData{event_type: type, data: Map.put(data, :run_id, run_id), metadata: %{}}
        end)
      )

    on_exit(fn -> Store.delete_stream(stream, :any_version, :hard) end)
  end

  # A terminal run with: out1, err1 (before) then steer + pause + resume (durable
  # events created "now"), so the sorted order is fixed regardless of wall clock.
  defp seed_run do
    run_id = uid("tr-run")

    append_run_events(run_id, [
      {"RunSteerQueued", %{message_id: uid("m"), text: "switch to plan B password=hunter2"}},
      {"RunPaused", %{reason: "steer"}},
      {"RunResumed", %{}}
    ])

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p-tr"}},
        stdout(run_id, 1, "out one", iso(-20_000)),
        stdout(run_id, 2, "out two", iso(-19_900)),
        stderr(run_id, 3, "err one token=sk-livesecret123", iso(-19_800)),
        %{event_type: "RunCompleted", payload: %{run_id: run_id, project_id: "p-tr"}}
      ])

    run_id
  end

  defp read_all(thread_id, limit) do
    Stream.unfold(-1, fn
      :done ->
        nil

      cursor ->
        {:ok, %Page{turns: turns, next_cursor: next}} =
          Transcript.page(thread_id, after: cursor, limit: limit)

        if turns == [], do: nil, else: {turns, next}
    end)
    |> Enum.to_list()
    |> List.flatten()
  end

  test "following next_cursor returns every turn exactly once, in order, redacted" do
    run_id = seed_run()
    thread_id = "run:#{run_id}"

    turns = read_all(thread_id, 2)

    assert Enum.map(turns, &{&1.seq, &1.source}) == [
             {0, "stdout"},
             {1, "stderr"},
             {2, "steer"},
             {3, "run_event"},
             {4, "run_event"}
           ]

    assert hd(turns).text == "out one\nout two"
    assert Enum.at(turns, 2).text == "switch to plan B password=[REDACTED]"
    assert Enum.at(turns, 3).text == "Run paused: steer"

    # the same turns come back as one big page
    assert {:ok, %Page{turns: ^turns, next_cursor: 4, terminal: true}} =
             Transcript.page(thread_id, limit: 100)

    for turn <- turns do
      refute turn.text =~ "sk-livesecret123"
      refute turn.text =~ "hunter2"
    end
  end

  test "an empty page keeps the caller's cursor" do
    run_id = seed_run()

    assert {:ok, %Page{turns: [], next_cursor: 4}} =
             Transcript.page("run:#{run_id}", after: 4)
  end

  test "appending output never renumbers earlier turns; the new turn arrives last" do
    run_id = seed_run()
    thread_id = "run:#{run_id}"
    before = read_all(thread_id, 100)

    :ok = ProjectionStore.apply_events([stdout(run_id, 4, "late line", iso(60_000))])

    after_append = read_all(thread_id, 100)

    assert Enum.take(after_append, length(before)) == before
    assert [%{seq: 5, text: "late line", source: "stdout"}] = Enum.drop(after_append, 5)

    # a client holding cursor 4 receives exactly the new turn
    assert {:ok, %Page{turns: [%{seq: 5}], next_cursor: 5}} =
             Transcript.page(thread_id, after: 4)
  end

  test "bounded run logs are reported as truncated with the omitted count" do
    run_id = uid("tr-bounded")

    entries =
      for n <- 1..501, do: stdout(run_id, n, "l#{n}", iso(-30_000 + n))

    :ok =
      ProjectionStore.apply_events(
        [%{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p-tr"}}] ++
          entries ++
          [%{event_type: "RunCompleted", payload: %{run_id: run_id, project_id: "p-tr"}}]
      )

    assert {:ok, %Page{truncated: true, omitted_entries: 1, turns: [turn]}} =
             Transcript.page("run:#{run_id}")

    refute turn.text =~ "l1\n"
    assert turn.text =~ "l501"
  end

  test "jobsite iterations become agent turns and say when a tail was truncated" do
    jobsite_id = uid("tr-job")

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "JobsiteStarted",
          payload: %{jobsite_id: jobsite_id, repo_path: "/r", strategy: "worktree"}
        },
        %{
          event_type: "JobsiteIterationCompleted",
          payload: %{
            jobsite_id: jobsite_id,
            index: 1,
            status: "completed",
            text: "worked on it Authorization: Bearer abc.def.ghi",
            text_truncated?: true
          }
        },
        %{
          event_type: "JobsiteIterationFailed",
          payload: %{jobsite_id: jobsite_id, index: 2, code: "boom", message: "agent crashed"}
        },
        %{
          event_type: "ReviewRecorded",
          payload: %{
            subject_kind: "jobsite",
            subject_id: jobsite_id,
            verdict: "partial",
            summary: "half done",
            at: "2026-01-01T00:00:00Z"
          }
        }
      ])

    assert {:ok, %Page{truncated: true, omitted_entries: 0, terminal: false, turns: turns}} =
             Transcript.page("jobsite:#{jobsite_id}")

    assert Enum.map(turns, &{&1.seq, &1.role, &1.kind, &1.source}) == [
             {0, :agent, :text, "jobsite_iteration"},
             {1, :system, :status, "jobsite_iteration"},
             {2, :system, :verdict, "review"}
           ]

    assert Enum.at(turns, 0).text =~ "Bearer [REDACTED]"
    refute Enum.at(turns, 0).text =~ "abc.def.ghi"
    assert Enum.at(turns, 1).text == "Iteration 2 failed: agent crashed"
    assert Enum.at(turns, 2).text == "partial: half done"
  end

  test "unknown threads and bad options are typed errors" do
    assert {:error, :thread_not_found} = Transcript.page("run:no-such-#{uid("x")}")
    assert {:error, :thread_not_found} = Transcript.page("garbage")
    assert {:error, {:invalid_option, :after}} = Transcript.page("run:x", after: -2)
    assert {:error, {:invalid_option, :limit}} = Transcript.page("run:x", limit: 0)
    assert {:error, {:invalid_option, :limit}} = Transcript.page("run:x", limit: 1001)
  end
end
