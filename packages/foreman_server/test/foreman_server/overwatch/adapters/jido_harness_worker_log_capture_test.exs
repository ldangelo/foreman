defmodule ForemanServer.Overwatch.Adapters.JidoHarnessWorkerLogCaptureTest do
  @moduledoc """
  Pins the harness-event -> durable-channel mapping that makes
  `foreman_run_get_logs` return anything at all.

  The defect these tests exist for: the capture originally selected only
  `:output_text_delta` / `:output_text_final` / `:command_output_delta`, then
  looked for a `"stream"` or `"channel"` key on those payloads to decide
  stdout vs stderr. `Jido.Harness` never puts either key on them — a
  `:command_output_delta` payload is only ever `%{"text" => text}`
  (`deps/jido_harness/lib/jido_harness/adapters/json_mapper.ex:51`). stderr
  travels on a completely different event: `ProcessEvent{type: :stderr}`
  becomes an `Event{type: :provider_event}` carrying
  `%{"stream" => "stderr", "data" => data}`
  (`adapters/cli_stream.ex:37-38`, `session/transports/pi_rpc.ex:138-140`).

  So `WorkerStderr` was unreachable: every stderr byte an agent wrote was
  dropped while the tool, the events, and the docs all advertised
  stdout/stderr capture. These assertions are the upgrade tripwire required
  by AGENTS.md 5.6 — if the harness changes where stderr rides, they fail
  here instead of silently emptying the stderr channel again.

  Each entry is a `WorkerLogEntry` and carries the harness `sequence` of its event. The live tail
  and the finished run deliver their entries through this one mapping, and the sequence is the
  cursor that lets the worker write a line once (`jido_harness_worker_live_output_test.exs`). A
  run numbers its events from 1, so an event without a sequence is refused, not skipped.
  """

  use ExUnit.Case, async: true

  alias ForemanServer.Overwatch.Adapters.JidoHarnessWorker
  alias ForemanServer.Overwatch.WorkerLogEntry

  defp event(type, payload, timestamp \\ "2026-08-27T00:00:00Z") do
    %Jido.Harness.Event{
      type: type,
      provider: :pi,
      payload: payload,
      timestamp: timestamp
    }
  end

  defp at(event, sequence), do: %{event | sequence: sequence}

  # A run numbers its events from 1 (`Jido.Harness.Event.attach/4`). An event built here without
  # a sequence takes its position in the list; one given a sequence keeps it.
  defp run_result(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn
      {%{sequence: 0} = event, position} -> at(event, position)
      {event, _position} -> event
    end)
    |> raw_run_result()
  end

  # The events exactly as given, whatever their sequences.
  defp raw_run_result(events) do
    %Jido.Harness.RunResult{
      run_id: "run-log-capture",
      provider: :pi,
      status: :completed,
      events: events
    }
  end

  test "stdout text events map to :worker_stdout using the string-keyed payload" do
    result =
      run_result([
        event(:output_text_delta, %{"text" => "partial"}),
        event(:output_text_final, %{"text" => "done"}),
        event(:command_output_delta, %{"text" => "cmd out"})
      ])

    assert [
             %{channel: :worker_stdout, data: "partial"},
             %{channel: :worker_stdout, data: "done"},
             %{channel: :worker_stdout, data: "cmd out"}
           ] = JidoHarnessWorker.log_events(result)
  end

  test "a provider_event carrying stream=stderr maps to :worker_stderr" do
    result = run_result([event(:provider_event, %{"stream" => "stderr", "data" => "boom\n"})])

    assert [%{channel: :worker_stderr, data: "boom\n", timestamp: "2026-08-27T00:00:00Z"}] =
             JidoHarnessWorker.log_events(result)
  end

  test "stdout and stderr are both captured from one run, in event order" do
    result =
      run_result([
        event(:output_text_delta, %{"text" => "step 1"}),
        event(:provider_event, %{"stream" => "stderr", "data" => "warning"}),
        event(:output_text_final, %{"text" => "step 2"})
      ])

    assert [
             %{channel: :worker_stdout, data: "step 1"},
             %{channel: :worker_stderr, data: "warning"},
             %{channel: :worker_stdout, data: "step 2"}
           ] = JidoHarnessWorker.log_events(result)
  end

  test "provider_events on other streams and unrelated event types are not captured" do
    result =
      run_result([
        event(:provider_event, %{"stream" => "stdout", "data" => "not this way"}),
        event(:provider_event, %{"session_id" => "abc"}),
        event(:run_failed, %{"error" => "nope"}),
        event(:output_text_delta, %{"no_text_key" => true})
      ])

    assert [] = JidoHarnessWorker.log_events(result)
  end

  test "a run with no events, or a non-RunResult, yields no logs" do
    assert [] = JidoHarnessWorker.log_events(run_result([]))
    assert [] = JidoHarnessWorker.log_events(:detached)
  end

  test "every entry carries the sequence of its harness event, in event order" do
    result =
      run_result([
        at(event(:output_text_delta, %{"text" => "one"}), 4),
        at(event(:turn_started, %{}), 5),
        at(event(:provider_event, %{"stream" => "stderr", "data" => "two"}), 6),
        at(event(:output_text_final, %{"text" => "three"}), 9)
      ])

    # An event that is not a log line leaves a hole in the sequences, never a placeholder entry.
    assert [
             %{data: "one", sequence: 4},
             %{data: "two", sequence: 6},
             %{data: "three", sequence: 9}
           ] = JidoHarnessWorker.log_events(result)
  end

  test "an entry is a WorkerLogEntry: its sequence cannot be left out" do
    assert [%WorkerLogEntry{channel: :worker_stdout, data: "one", sequence: 1}] =
             JidoHarnessWorker.log_events(
               run_result([event(:output_text_delta, %{"text" => "one"})])
             )

    # The keys are enforced: an entry without a sequence cannot be built, instead of failing with
    # a `KeyError` once the worker reads it.
    assert_raise ArgumentError, ~r/must also be given/, fn ->
      struct!(WorkerLogEntry,
        channel: :worker_stdout,
        data: "one",
        timestamp: "2026-08-27T00:00:00Z"
      )
    end
  end

  test "an event no run has numbered is refused, not skipped" do
    # 0 is the default of an event no run has seen (`Jido.Harness.Event`), and the cursor a line
    # is written by would skip such an entry without a word.
    for sequence <- [0, -1, nil] do
      result = raw_run_result([at(event(:output_text_delta, %{"text" => "one"}), sequence)])

      assert_raise ArgumentError, ~r/positive sequence/, fn ->
        JidoHarnessWorker.log_events(result)
      end
    end

    # An event that is not a log line never becomes an entry, so its sequence does not matter.
    assert [] = JidoHarnessWorker.log_events(raw_run_result([event(:turn_started, %{})]))
  end

  describe "upstream contract (AGENTS.md 5.6)" do
    test "jido_harness still routes ProcessEvent stderr onto provider_event/stream=stderr" do
      source =
        File.read!(
          Path.join(
            __DIR__,
            "../../../../../jido_harness/lib/jido_harness/adapters/cli_stream.ex"
          )
        )

      assert source =~ "%ProcessEvent{type: :stderr, data: data}"

      assert source =~ ~s(:provider_event, nil, %{"stream" => "stderr", "data" => data})
    end

    test "jido_harness still builds text payloads under the string key \"text\"" do
      source =
        File.read!(
          Path.join(
            __DIR__,
            "../../../../../jido_harness/lib/jido_harness/adapters/json_mapper.ex"
          )
        )

      assert source =~ ~s(:command_output_delta, session_id, %{"text" => text})
    end
  end
end
