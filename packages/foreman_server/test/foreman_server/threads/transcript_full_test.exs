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
end
