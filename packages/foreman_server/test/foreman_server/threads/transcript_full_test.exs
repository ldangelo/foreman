defmodule ForemanServer.Threads.TranscriptFullTest do
  # `Transcript.full/2` is every turn of a thread (what the workspace's thread pane re-reads);
  # `page/2` is that list sliced by cursor, so the two must agree on content and redaction.
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads.Transcript
  alias ForemanServer.Threads.Transcript.{Full, Page}

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

  # A finished run: output, a steer holding a secret, a pause and its resume.
  defp seed_finished_run do
    run_id = uid("tf-run")

    append_run_events(run_id, [
      {"RunSteerQueued", %{message_id: uid("m"), text: "switch to plan B password=hunter2"}},
      {"RunPaused", %{reason: "steer"}},
      {"RunResumed", %{}}
    ])

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p-tf"}},
        stdout(run_id, 1, "out one", iso(-20_000)),
        stderr(run_id, 2, "err one token=sk-livesecret123", iso(-19_800)),
        %{event_type: "RunCompleted", payload: %{run_id: run_id, project_id: "p-tf"}}
      ])

    run_id
  end

  describe "full/2" do
    test "returns every turn, in order and redacted, exactly as one big page does" do
      thread_id = "run:" <> seed_finished_run()

      assert {:ok, %Full{turns: turns, terminal: true, truncated: false, omitted_entries: 0}} =
               Transcript.full(thread_id)

      assert Enum.map(turns, &{&1.seq, &1.source}) == [
               {0, "stdout"},
               {1, "stderr"},
               {2, "steer"},
               {3, "run_event"},
               {4, "run_event"}
             ]

      assert Enum.at(turns, 2).text == "switch to plan B password=[REDACTED]"
      refute Enum.any?(turns, &(&1.text =~ "sk-livesecret123" or &1.text =~ "hunter2"))

      assert {:ok, %Page{turns: ^turns, terminal: true}} = Transcript.page(thread_id, limit: 1000)
    end

    test "a cursor page is a slice of the full list" do
      thread_id = "run:" <> seed_finished_run()
      {:ok, %Full{turns: turns}} = Transcript.full(thread_id)

      assert {:ok, %Page{turns: page_turns, next_cursor: 3}} =
               Transcript.page(thread_id, after: 1, limit: 2)

      assert page_turns == Enum.slice(turns, 2, 2)
    end

    test "a small gap and a clock show the trailing agent turn of a live run at once" do
      run_id = uid("tf-live")

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p-tf"}},
          stdout(run_id, 1, "still thinking", iso(-50))
        ])

      thread_id = "run:" <> run_id

      # The default holds the trailing turn back: a later line could still extend it.
      assert {:ok, %Full{turns: [], terminal: false}} = Transcript.full(thread_id)

      now = System.system_time(:millisecond) + 5

      assert {:ok, %Full{turns: [%{text: "still thinking", source: "stdout"}], terminal: false}} =
               Transcript.full(thread_id, now_ms: now, gap_ms: 0)
    end

    test "unknown threads are a typed error, never an empty transcript" do
      assert {:error, :thread_not_found} = Transcript.full("run:no-such-#{uid("x")}")
      assert {:error, :thread_not_found} = Transcript.full("jobsite:no-such-#{uid("x")}")
      assert {:error, :thread_not_found} = Transcript.full("garbage")
    end
  end

  describe "full/2 with chunks: true" do
    # A finished run: three stdout chunks and a stderr chunk, all stamped the same millisecond,
    # then a steer, a pause and its resume.
    defp seed_chunked_run do
      run_id = uid("tf-chunks")
      at = iso(-20_000)

      append_run_events(run_id, [
        {"RunSteerQueued", %{message_id: uid("m"), text: "go on password=hunter2"}},
        {"RunPaused", %{reason: "steer"}},
        {"RunResumed", %{}}
      ])

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p-tf"}},
          stdout(run_id, 1, "Star", at),
          stdout(run_id, 2, "ting", at),
          stdout(run_id, 3, "Starting", at),
          stderr(run_id, 4, "warn token=sk-livesecret123\n", at),
          %{event_type: "RunCompleted", payload: %{run_id: run_id, project_id: "p-tf"}}
        ])

      run_id
    end

    test "is one turn per stored entry, text exactly as stored, also for entries of one millisecond" do
      thread_id = "run:" <> seed_chunked_run()

      assert {:ok, %Full{turns: turns, terminal: true}} = Transcript.full(thread_id, chunks: true)

      assert Enum.map(turns, &{&1.seq, &1.role, &1.kind, &1.source}) == [
               {0, :agent, :text, "stdout"},
               {1, :agent, :text, "stdout"},
               {2, :agent, :text, "stdout"},
               {3, :agent, :text, "stderr"},
               {4, :operator, :steer, "steer"},
               {5, :system, :status, "run_event"},
               {6, :system, :status, "run_event"}
             ]

      assert Enum.map(Enum.take(turns, 3), & &1.text) == ["Star", "ting", "Starting"]

      # the stderr chunk keeps its own newline; redaction is the same as ever
      assert Enum.at(turns, 3).text =~ ~r/^warn token=.*\n$/
      assert Enum.at(turns, 4).text == "go on password=[REDACTED]"
      refute Enum.any?(turns, &(&1.text =~ "sk-livesecret123" or &1.text =~ "hunter2"))
    end

    test "nothing is withheld while the run is live: no gap and no clock needed" do
      run_id = uid("tf-chunks-live")

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p-tf"}},
          stdout(run_id, 1, "Star", iso(-50)),
          stdout(run_id, 2, "ting", iso(-50))
        ])

      thread_id = "run:" <> run_id

      assert {:ok, %Full{turns: [%{text: "Star"}, %{text: "ting"}], terminal: false}} =
               Transcript.full(thread_id, chunks: true)

      # the grouped list holds the trailing turn back, as it always did
      assert {:ok, %Full{turns: []}} = Transcript.full(thread_id)
    end

    test "page/2 is unchanged: the same data stays grouped, and a chunks option handed to it is ignored" do
      thread_id = "run:" <> seed_chunked_run()

      assert {:ok, %Page{turns: grouped}} = Transcript.page(thread_id, limit: 1000)

      assert Enum.map(Enum.take(grouped, 2), &{&1.seq, &1.source}) == [
               {0, "stdout"},
               {1, "stderr"}
             ]

      assert hd(grouped).text == "Star\nting\nStarting"
      assert length(grouped) == 5

      assert {:ok, %Page{turns: ^grouped}} = Transcript.page(thread_id, limit: 1000, chunks: true)
    end
  end

  describe "full/2 with log_limit:" do
    # A run whose output is 505 chunks: one more than the API's tail holds, five more.
    defp seed_long_run do
      run_id = uid("tf-long")

      :ok =
        ProjectionStore.apply_events(
          [%{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p-tf"}}] ++
            for n <- 1..505 do
              stdout(run_id, n, "chunk-#{n} ", iso(-60_000 + n))
            end
        )

      "run:" <> run_id
    end

    test "reads more of the run's output than the default tail, and says what is still missing" do
      thread_id = seed_long_run()

      assert {:ok, %Full{turns: turns, truncated: true, omitted_entries: 5}} =
               Transcript.full(thread_id, chunks: true)

      assert length(turns) == 500
      assert hd(turns).text == "chunk-6 "

      assert {:ok, %Full{turns: all, truncated: false, omitted_entries: 0}} =
               Transcript.full(thread_id,
                 chunks: true,
                 log_limit: ProjectionStore.run_logs_max_limit()
               )

      assert length(all) == 505
      assert hd(all).text == "chunk-1 "

      assert {:ok, %Full{turns: few, truncated: true, omitted_entries: 405}} =
               Transcript.full(thread_id, chunks: true, log_limit: 100)

      assert length(few) == 100
    end

    test "page/2 never reads a longer log: the API is the tail it always was" do
      thread_id = seed_long_run()

      assert {:ok, %Page{omitted_entries: 5, truncated: true} = page} =
               Transcript.page(thread_id, limit: 1000)

      assert {:ok, ^page} = Transcript.page(thread_id, limit: 1000, log_limit: 5_000)
    end

    test "a limit the store does not accept raises, it is not clamped" do
      thread_id = seed_long_run()

      for limit <- [0, -1, 5_001, "5", nil] do
        assert_raise ArgumentError, fn -> Transcript.full(thread_id, log_limit: limit) end
      end
    end
  end
end
