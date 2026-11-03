defmodule ForemanServer.Overwatch.Adapters.JidoHarnessWorkerLiveOutputTest do
  @moduledoc """
  A running agent's stdout/stderr is recorded in its worker stream WHILE it runs
  (bead foreman-h1j5y).

  `JidoHarnessWorker` used to build every `WorkerStdout` / `WorkerStderr` entry from the
  finished `RunResult`, so until the agent exited its worker stream held `WorkerStarted` and
  heartbeats only: `run_logs` and the thread transcript stayed empty for the whole phase. And
  because a `RunResult` carries only the harness's in-memory event window (1 MiB by default),
  the OLDEST part of a long phase's output was never recorded at all.

  The agent here is a stand-in harness provider (the `DriverTest.Stub` pattern) that produces
  what the test tells it to and then BLOCKS until the test releases it. That is the barrier:
  the release (`:finish`) is only ever sent after the assertion that the output is already in
  the worker stream, so output that is recorded only when the agent exits can never pass.
  Everything else is waited for on a message (the worker stream's own subscription), never a
  sleep.

  Some behaviour has no honest trigger in the agent's own output, so a few tests below pull a
  lever instead and say so where they do: they pause the worker or the tracker so that the order
  of messages is certain rather than likely, send the worker the message its tail would send,
  kill the tail or the worker, or trace what the worker receives.
  """

  use ExUnit.Case, async: false

  # A task crash and a worker shutdown are on purpose here: their reports are not output.
  @moduletag :capture_log

  import ExUnit.CaptureLog, only: [capture_log: 2]

  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.Adapters.JidoHarnessWorker
  alias ForemanServer.Overwatch.Tracker
  alias ForemanServer.Overwatch.WorkerLogEntry
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  # Only an upper bound on how long a failing test waits before it reports; nothing below
  # depends on it elapsing.
  @await_ms 10_000

  @log_types ["WorkerStdout", "WorkerStderr"]

  @claude_usage %{
    "input_tokens" => 10,
    "output_tokens" => 5,
    "cache_read_input_tokens" => 100,
    "cache_creation_input_tokens" => 20
  }

  defmodule ControlledAgent do
    @moduledoc false
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :claude,
        name: "controlled agent",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :claude,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: %Capabilities{streaming?: true, resume?: true},
         executable: "stub"
       }}
    end

    # Runs in the harness's adapter task. It reports itself and its run to the test, then yields
    # exactly the events the test sends it (`{:emit, events}`) and stays open until `:finish`.
    @impl true
    def run(request, context) do
      agent = %{adapter: self(), run: context.run_owner, harness_run_id: context.run_id}
      send(Map.fetch!(request.metadata, :control), {:agent_started, agent})
      {:ok, Stream.resource(fn -> :ok end, &next/1, fn _ -> :ok end)}
    end

    defp next(state) do
      receive do
        {:emit, events} -> {events, state}
        :finish -> {:halt, state}
      end
    end
  end

  setup do
    providers = Application.get_env(:jido_harness, :providers, %{})
    process_manager = Application.get_env(:jido_harness, :process_manager, %{})

    journals =
      Path.join(System.tmp_dir!(), "live-output-journals-#{System.unique_integer([:positive])}")

    Application.put_env(:jido_harness, :providers, %{claude: ControlledAgent})

    Application.put_env(
      :jido_harness,
      :process_manager,
      process_manager |> Map.new() |> Map.put(:journal_dir, journals)
    )

    on_exit(fn ->
      Application.put_env(:jido_harness, :providers, providers)
      Application.put_env(:jido_harness, :process_manager, process_manager)
      File.rm_rf(journals)
    end)

    start_supervised!({Tracker, []}, id: :tracker)

    worker_id = uuid()
    run_id = uuid()
    :ok = Store.subscribe(Tracker.stream_id(worker_id, run_id))

    {:ok, worker_id: worker_id, run_id: run_id}
  end

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp stdout(text),
    do: Event.new!(provider: :claude, type: :output_text_delta, payload: %{"text" => text})

  defp stderr(text),
    do:
      Event.new!(
        provider: :claude,
        type: :provider_event,
        payload: %{"stream" => "stderr", "data" => text}
      )

  # An event that is not a log line: the tail reads it, the mapping leaves it out.
  defp quiet,
    do: Event.new!(provider: :claude, type: :provider_event, payload: %{"kind" => "quiet"})

  # What a finished claude run reports besides its output: a provider session and token usage.
  defp bookkeeping do
    [
      Event.new!(
        provider: :claude,
        type: :usage,
        provider_session_id: "session-live",
        payload: @claude_usage
      )
    ]
  end

  # Starts a worker the way `LaunchWorker` does (start, activate) around a controlled agent. The
  # agent is released when the test ends, pass or fail.
  defp start_agent(worker_id, run_id, extra_opts \\ []) do
    opts =
      [
        worker_id: worker_id,
        run_id: run_id,
        provider: :claude,
        prompt: "go",
        project_id: "proj-live",
        task_id: "task-live",
        result_recipient: self(),
        driver_opts: [metadata: %{control: self()}]
      ] ++ extra_opts

    worker =
      start_supervised!(%{
        id: {JidoHarnessWorker, worker_id},
        start: {JidoHarnessWorker, :start_link, [opts]},
        restart: :temporary
      })

    send(worker, {:overwatch_activate, worker_id, run_id, self()})
    assert_receive {:overwatch_activated, ^worker}, @await_ms
    assert_receive {:agent_started, agent}, @await_ms
    on_exit(fn -> send(agent.adapter, :finish) end)

    {worker, agent}
  end

  # Worker-stream events, as they are announced, until `done?` is satisfied by all seen so far.
  # `@await_ms` bounds the WHOLE wait: heartbeats keep arriving, so an idle timeout alone would
  # never report a line that is missing.
  defp await_events(done?, timeout_ms \\ @await_ms),
    do: await_events(done?, [], System.monotonic_time(:millisecond) + timeout_ms)

  defp await_events(done?, seen, deadline) do
    if done?.(seen) do
      seen
    else
      assert_receive {:events, events}, max(deadline - System.monotonic_time(:millisecond), 0)
      await_events(done?, seen ++ events, deadline)
    end
  end

  # The log lines that have reached the worker stream, oldest first, once `count` are in.
  defp await_log_lines(count) do
    seen = await_events(fn seen -> length(lines(seen)) >= count end)
    lines(seen)
  end

  defp lines(events),
    do: for(%{event_type: type} = event <- events, type in @log_types, do: log(event))

  defp log(%{event_type: type, data: %{"line" => line}}), do: {type, line}

  defp stream(worker_id, run_id) do
    {:ok, events} = Store.read_stream_forward(Tracker.stream_id(worker_id, run_id), 0, 99_999_999)
    events
  end

  # The worker's log tail: the process the worker spawned and MONITORS without being linked to it
  # (a tail that fails must not take the agent's worker down). The agent task, its other child, is
  # linked as well. A call in progress (a heartbeat, a write) adds a monitor for its duration, so
  # a process the worker monitors is the tail only if the worker is also its parent.
  defp tail_of(worker) do
    {:monitors, monitors} = Process.info(worker, :monitors)
    {:links, links} = Process.info(worker, :links)

    [tail] =
      Enum.uniq(
        for {:process, pid} <- monitors,
            pid not in links,
            Process.info(pid, :parent) == {:parent, worker},
            do: pid
      )

    tail
  end

  defp stream_version(worker_id, run_id) do
    case stream(worker_id, run_id) do
      [] -> 0
      events -> List.last(events).stream_version
    end
  end

  # Waits for `count` heartbeats recorded after stream version `version`. They come from the
  # worker's own timer, so each one shows the worker alive and answering at that moment.
  defp await_heartbeats_after(version, count) do
    await_events(fn seen ->
      Enum.count(seen, &(&1.event_type == "WorkerHeartbeat" and &1.stream_version > version)) >=
        count
    end)
  end

  defp entry(sequence, text) do
    %WorkerLogEntry{
      channel: :worker_stdout,
      data: text,
      timestamp: "2026-11-02T00:00:00Z",
      sequence: sequence
    }
  end

  # The entries of the pages the traced worker receives, in the order it receives them, once
  # `count` of them have arrived.
  defp await_page_entries(worker, count, entries \\ []) do
    if length(entries) >= count do
      entries
    else
      receive do
        {:trace, ^worker, :receive, {:harness_logs, _tail, page}} ->
          await_page_entries(worker, count, entries ++ page)
      after
        @await_ms -> flunk("the worker received #{length(entries)} of #{count} entries")
      end
    end
  end

  # What the traced harness run is asked, oldest first, until its latest `Run.replay/2` has been
  # followed by `idle` calls of `Run.info/1`: `{:info, at}` and `{:replay, cursor, at}`, `at` being
  # when the run received the call, in native time units.
  defp harness_calls(run, idle, calls \\ []) do
    {infos, rest} = Enum.split_while(calls, &match?({:info, _}, &1))

    if length(infos) >= idle and match?([{:replay, _, _} | _], rest) do
      Enum.reverse(calls)
    else
      receive do
        {:trace_ts, ^run, :receive, {:"$gen_call", _from, :info}, at} ->
          harness_calls(run, idle, [{:info, at} | calls])

        {:trace_ts, ^run, :receive, {:"$gen_call", _from, {:replay, cursor, _limit}}, at} ->
          harness_calls(run, idle, [{:replay, cursor, at} | calls])

        {:trace_ts, ^run, :receive, _other, _at} ->
          harness_calls(run, idle, calls)
      after
        @await_ms ->
          flunk("the harness run was not asked often enough: #{inspect(Enum.reverse(calls))}")
      end
    end
  end

  describe "while the agent runs" do
    test "what it has written is in the worker stream before it finishes", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {_worker, agent} = start_agent(worker_id, run_id)

      send(agent.adapter, {:emit, [stdout("step 1"), stderr("a warning"), stdout("step 2")]})

      # The agent is blocked on `:finish`, which only this test sends, after this assertion.
      assert [
               {"WorkerStdout", "step 1"},
               {"WorkerStderr", "a warning"},
               {"WorkerStdout", "step 2"}
             ] =
               await_log_lines(3)

      refute_received {:worker_result, _}

      send(agent.adapter, :finish)
      assert_receive {:worker_result, {:ok, _text}}, @await_ms
    end

    test "a live line is redacted like one written when the agent exits", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {_worker, agent} = start_agent(worker_id, run_id, secrets: ["s3cr3t-value"])

      send(agent.adapter, {:emit, [stdout("calling the api with s3cr3t-value now")]})

      assert [{"WorkerStdout", line}] = await_log_lines(1)
      assert line =~ "[REDACTED]"
      refute line =~ "s3cr3t-value"
    end

    test "output the harness no longer holds in memory is recorded as it is produced", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      # A buffer of a handful of events instead of 1 MiB: what a real phase reaches after a few
      # minutes. The finished run then carries only the NEWEST events.
      provider_config = Application.get_env(:jido_harness, :provider_config, %{})

      Application.put_env(
        :jido_harness,
        :provider_config,
        Map.put(provider_config, :claude, %{retention: %{memory_bytes: 1_500}})
      )

      on_exit(fn -> Application.put_env(:jido_harness, :provider_config, provider_config) end)

      {_worker, agent} = start_agent(worker_id, run_id)
      texts = for n <- 1..20, do: "line #{n}"

      send(agent.adapter, {:emit, Enum.map(texts, &stdout/1)})
      assert Enum.map(await_log_lines(20), &elem(&1, 1)) == texts

      send(agent.adapter, :finish)
      assert_receive {:worker_result, {:ok, _text}}, @await_ms

      # Without this the test would prove nothing: the run's own result no longer holds the
      # first lines, so recording only what it holds (the old behaviour) loses them.
      assert {:ok, run_result} = Jido.Harness.Run.await(agent.harness_run_id, @await_ms)
      assert length(JidoHarnessWorker.log_events(run_result)) < 20
      assert Enum.map(lines(stream(worker_id, run_id)), &elem(&1, 1)) == texts
    end

    test "every line is written once and in order, ahead of the session, usage and exit events",
         %{
           worker_id: worker_id,
           run_id: run_id
         } do
      {worker, agent} = start_agent(worker_id, run_id)
      worker_down = Process.monitor(worker)

      live = [stdout("one"), stderr("two")]
      send(agent.adapter, {:emit, live})
      assert [{"WorkerStdout", "one"}, {"WorkerStderr", "two"}] = await_log_lines(2)

      # More output, the session and usage, and the agent ends at once. What the tail has not
      # delivered by then comes from the finished run, which holds "one" and "two" as well: those
      # were written live and must not be written again.
      rest = [stdout("three"), stderr("four")]
      send(agent.adapter, {:emit, rest ++ bookkeeping()})
      send(agent.adapter, :finish)

      assert_receive {:worker_result, {:ok, _text}}, @await_ms
      assert_receive {:DOWN, ^worker_down, :process, ^worker, :normal}, @await_ms

      events = stream(worker_id, run_id)

      assert Enum.map(events, & &1.event_type) == [
               "WorkerStdout",
               "WorkerStderr",
               "WorkerStdout",
               "WorkerStderr",
               "WorkerSessionBound",
               "UsageRecorded",
               "WorkerExited"
             ]

      assert lines(events) == [
               {"WorkerStdout", "one"},
               {"WorkerStderr", "two"},
               {"WorkerStdout", "three"},
               {"WorkerStderr", "four"}
             ]

      # The harness's own timestamps travel with the lines, live and at exit alike.
      assert events
             |> Enum.filter(&(&1.event_type in @log_types))
             |> Enum.map(& &1.data["timestamp"]) ==
               Enum.map(live ++ rest, & &1.timestamp)

      assert %{"worker_id" => ^worker_id, "run_id" => ^run_id, "line" => "one"} = hd(events).data
    end

    test "a tail that falls behind loses nothing: the finished run supplies the rest", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {worker, agent} = start_agent(worker_id, run_id)
      worker_down = Process.monitor(worker)

      send(agent.adapter, {:emit, [stdout("seen live")]})
      assert [{"WorkerStdout", "seen live"}] = await_log_lines(1)

      # Freeze the tail so that "it is behind" is certain, not just likely: from here on it
      # delivers nothing. `suspend_process/1` is a debugging BIF, used here as a test lever.
      tail = tail_of(worker)
      tail_down = Process.monitor(tail)
      true = :erlang.suspend_process(tail)

      send(agent.adapter, {:emit, [stderr("only in the finished run"), stdout("and this")]})
      send(agent.adapter, :finish)

      assert_receive {:worker_result, {:ok, _text}}, @await_ms
      assert_receive {:DOWN, ^worker_down, :process, ^worker, :normal}, @await_ms

      assert lines(stream(worker_id, run_id)) == [
               {"WorkerStdout", "seen live"},
               {"WorkerStderr", "only in the finished run"},
               {"WorkerStdout", "and this"}
             ]

      # The exit stopped the tail, frozen or not.
      assert_receive {:DOWN, ^tail_down, :process, ^tail, _reason}, @await_ms
    end

    test "a line queued behind the agent's result is never written", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {worker, agent} = start_agent(worker_id, run_id)

      send(agent.adapter, {:emit, [stdout("early")]})
      assert [{"WorkerStdout", "early"}] = await_log_lines(1)
      tail = tail_of(worker)

      # While the worker is not running, queue the agent's result and then one more page from the
      # tail: they are handled in the order they were queued, so the page is the late one.
      worker_down = Process.monitor(worker)
      :ok = :sys.suspend(worker)
      send(worker, {:agent_done, {:ok, "done"}, [entry(1_000, "from the result")], nil})
      send(worker, {:harness_logs, tail, [entry(1_001, "too late")]})
      :ok = :sys.resume(worker)

      assert_receive {:worker_result, {:ok, "done"}}, @await_ms
      assert_receive {:DOWN, ^worker_down, :process, ^worker, :normal}, @await_ms

      events = stream(worker_id, run_id)
      assert lines(events) == [{"WorkerStdout", "early"}, {"WorkerStdout", "from the result"}]
      assert List.last(events).event_type == "WorkerExited"
    end

    test "heartbeats keep firing while output is tailed", %{worker_id: worker_id, run_id: run_id} do
      {worker, agent} = start_agent(worker_id, run_id, heartbeat_interval_ms: 10)
      :ok = Tracker.register(worker_id, run_id, worker)

      send(agent.adapter, {:emit, [stdout("a"), stdout("b")]})

      # Output and several heartbeats are both recorded while the agent is still blocked: the
      # worker serves its heartbeats and the tail at once.
      seen =
        await_events(fn seen ->
          length(lines(seen)) >= 2 and
            Enum.count(seen, &(&1.event_type == "WorkerHeartbeat")) >= 3
        end)

      assert [{"WorkerStdout", "a"}, {"WorkerStdout", "b"}] = lines(seen)
      refute_received {:worker_result, _}

      send(agent.adapter, :finish)
      assert_receive {:worker_result, {:ok, _text}}, @await_ms
    end

    test "a burst of output does not hold the heartbeats back, and every line is written once, in order",
         %{worker_id: worker_id, run_id: run_id} do
      {worker, agent} = start_agent(worker_id, run_id, heartbeat_interval_ms: 5)
      :ok = Tracker.register(worker_id, run_id, worker)

      # 1,200 events: three pages of the tail (500 events each) with 240 log lines spread over
      # them. While the first page is written the other two are already waiting. Every write is a
      # call through the Tracker, so the lines take seconds, all of it the worker's own turn.
      texts = for n <- 1..240, do: "line #{n}"

      send(
        agent.adapter,
        {:emit, Enum.flat_map(texts, &[stdout(&1) | List.duplicate(quiet(), 4)])}
      )

      seen = await_events(fn seen -> length(lines(seen)) >= length(texts) end, 30_000)

      # Order, and every line exactly once, across the pages.
      assert Enum.map(lines(seen), &elem(&1, 1)) == texts

      # The worker's own timer was served between its first line and its last, not after them: a
      # heartbeat after about every slice of 25 entries (9 slices apart here). Held back until a
      # page, or the whole burst, was written it would show at most two.
      kinds = Enum.map(seen, & &1.event_type)
      first = Enum.find_index(kinds, &(&1 in @log_types))
      last = length(kinds) - 1 - Enum.find_index(Enum.reverse(kinds), &(&1 in @log_types))
      assert Enum.count(Enum.slice(kinds, first..last), &(&1 == "WorkerHeartbeat")) >= 6

      send(agent.adapter, :finish)
      assert_receive {:worker_result, {:ok, _text}}, @await_ms
    end

    test "the tail sends an entry once, however many rounds it takes", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {worker, agent} = start_agent(worker_id, run_id)

      # Every message the worker receives is announced to this test, so the pages of the tail can
      # be counted. The stream cannot show a page sent twice: the worker writes an entry once
      # however often it is sent it.
      :erlang.trace(worker, true, [:receive])

      send(agent.adapter, {:emit, [stdout("one"), stderr("two")]})
      assert [{"WorkerStdout", "one"}, {"WorkerStderr", "two"}] = await_log_lines(2)

      # The next page can only come from a later round: a tail that went back over what it had
      # sent would send "one" and "two" again with it.
      send(agent.adapter, {:emit, [stdout("three")]})
      assert [{"WorkerStdout", "three"}] = await_log_lines(1)

      sequences = worker |> await_page_entries(3) |> Enum.map(& &1.sequence)
      assert length(sequences) == 3
      assert sequences == Enum.sort(Enum.uniq(sequences))
    end

    test "an idle tail asks the run one cheap question per poll period and replays nothing", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {_worker, agent} = start_agent(worker_id, run_id)

      # What the harness run is asked, and when. The tail's rounds are its `Run.info/1` calls, and
      # its `Run.replay/2` calls when `info` says there is more to read.
      :erlang.trace(agent.run, true, [:receive, :monotonic_timestamp])
      send(agent.adapter, {:emit, [stdout("one")]})
      assert [{"WorkerStdout", "one"}] = await_log_lines(1)

      # The round that read the output, then three rounds that found nothing new: no replay among
      # them.
      assert [
               {:info, read_at},
               {:replay, _cursor, _at},
               {:info, idle_1},
               {:info, idle_2},
               {:info, idle_3}
             ] = Enum.take(harness_calls(agent.run, 3), -5)

      # A page that was not full, and a round that found nothing, are each followed by a poll
      # period before the next call, never by the next call at once.
      poll = System.convert_time_unit(200, :millisecond, :native)
      assert idle_1 - read_at >= poll
      assert idle_2 - idle_1 >= poll
      assert idle_3 - idle_2 >= poll
    end

    test "entries the tail delivered but the worker has not written when the agent exits are written first, once, in order",
         %{worker_id: worker_id, run_id: run_id} do
      {worker, agent} = start_agent(worker_id, run_id)

      send(agent.adapter, {:emit, [stdout("early")]})
      assert [{"WorkerStdout", "early"}] = await_log_lines(1)
      tail = tail_of(worker)

      # What the tail sent and what the finished run holds overlap. While the worker is not
      # running, a page reaches it with the agent's result right behind: the page is queued, not
      # written, when the agent exits.
      page = for n <- 1_000..1_039, do: entry(n, "page #{n}")
      result_entries = for n <- 1_030..1_042, do: entry(n, "page #{n}")

      worker_down = Process.monitor(worker)
      :ok = :sys.suspend(worker)
      send(worker, {:harness_logs, tail, page})
      send(worker, {:agent_done, {:ok, "done"}, result_entries, nil})
      :ok = :sys.resume(worker)

      assert_receive {:worker_result, {:ok, "done"}}, @await_ms
      assert_receive {:DOWN, ^worker_down, :process, ^worker, :normal}, @await_ms

      events = stream(worker_id, run_id)

      assert Enum.map(lines(events), &elem(&1, 1)) ==
               ["early" | for(n <- 1_000..1_042, do: "page #{n}")]

      assert List.last(events).event_type == "WorkerExited"
    end

    test "the line and byte caps count what is written live and at exit together", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      # The finished run must still hold all six lines below, so its window is widened.
      provider_config = Application.get_env(:jido_harness, :provider_config, %{})

      Application.put_env(
        :jido_harness,
        :provider_config,
        Map.put(provider_config, :claude, %{retention: %{memory_bytes: 32 * 1024 * 1024}})
      )

      on_exit(fn -> Application.put_env(:jido_harness, :provider_config, provider_config) end)

      # `WorkerLogPolicy` keeps at most 5 MiB per worker. Of lines of 1,000,000 bytes, five fit.
      big = fn n -> String.pad_trailing("line #{n} ", 1_000_000, "x") end
      {worker, agent} = start_agent(worker_id, run_id)
      worker_down = Process.monitor(worker)

      send(agent.adapter, {:emit, for(n <- 1..3, do: stdout(big.(n)))})
      assert [_, _, _] = await_log_lines(3)

      # From here on only the finished run supplies lines.
      true = :erlang.suspend_process(tail_of(worker))
      send(agent.adapter, {:emit, for(n <- 4..6, do: stdout(big.(n)))})
      send(agent.adapter, :finish)

      assert_receive {:worker_result, {:ok, _text}}, @await_ms
      assert_receive {:DOWN, ^worker_down, :process, ^worker, :normal}, @await_ms

      # Three lines written live and the 4th and 5th at exit make 5,000,000 bytes: the 6th does
      # not fit. Were the two paths to count apart, exit would write the 4th to the 6th.
      written = worker_id |> stream(run_id) |> lines()

      assert Enum.map(written, fn {_type, line} -> String.slice(line, 0, 6) end) ==
               for(n <- 1..5, do: "line #{n}")
    end
  end

  describe "when the agent does not finish normally" do
    test "output written before the harness run dies stays recorded, and nothing keeps tailing",
         %{
           worker_id: worker_id,
           run_id: run_id
         } do
      {worker, agent} = start_agent(worker_id, run_id)

      send(agent.adapter, {:emit, [stdout("before the crash")]})
      assert [{"WorkerStdout", "before the crash"}] = await_log_lines(1)

      tail = tail_of(worker)
      tail_down = Process.monitor(tail)
      worker_down = Process.monitor(worker)

      # The harness run process dies under the agent task that is awaiting it: the task exits, and
      # the worker, linked to it, goes with it.
      Process.exit(agent.run, :kill)

      assert_receive {:DOWN, ^worker_down, :process, ^worker, reason}, @await_ms
      assert reason != :normal
      assert_receive {:DOWN, ^tail_down, :process, ^tail, _reason}, @await_ms

      # A crashed task is a crashed worker, not a result: nothing is reported to the recipient.
      refute_received {:worker_result, _}

      assert lines(stream(worker_id, run_id)) == [{"WorkerStdout", "before the crash"}]
    end

    test "a cancelled agent keeps what it had written", %{worker_id: worker_id, run_id: run_id} do
      {worker, agent} = start_agent(worker_id, run_id)
      worker_down = Process.monitor(worker)

      send(agent.adapter, {:emit, [stdout("before the cancel")]})
      assert [{"WorkerStdout", "before the cancel"}] = await_log_lines(1)

      # What `RunControl.cancel/1` does to a running agent.
      assert :ok = Jido.Harness.Run.cancel(agent.harness_run_id)

      assert_receive {:worker_result, {:error, _reason}}, @await_ms
      assert_receive {:DOWN, ^worker_down, :process, ^worker, :normal}, @await_ms

      events = stream(worker_id, run_id)
      assert lines(events) == [{"WorkerStdout", "before the cancel"}]
      assert List.last(events).event_type == "WorkerExited"
    end

    test "a worker that is shut down takes its tail with it", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {worker, agent} = start_agent(worker_id, run_id)

      send(agent.adapter, {:emit, [stdout("before the shutdown")]})
      assert [{"WorkerStdout", "before the shutdown"}] = await_log_lines(1)

      tail = tail_of(worker)
      tail_down = Process.monitor(tail)
      worker_down = Process.monitor(worker)

      Process.exit(worker, :shutdown)

      assert_receive {:DOWN, ^worker_down, :process, ^worker, :shutdown}, @await_ms
      assert_receive {:DOWN, ^tail_down, :process, ^tail, _reason}, @await_ms

      assert lines(stream(worker_id, run_id)) == [{"WorkerStdout", "before the shutdown"}]
    end

    test "a worker that is killed takes its tail with it", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {worker, agent} = start_agent(worker_id, run_id)

      send(agent.adapter, {:emit, [stdout("before the kill")]})
      assert [{"WorkerStdout", "before the kill"}] = await_log_lines(1)

      tail = tail_of(worker)
      tail_down = Process.monitor(tail)
      worker_down = Process.monitor(worker)

      # `:kill` runs nothing in the worker, no cleanup of any kind: the tail has to find out by
      # itself.
      Process.exit(worker, :kill)

      assert_receive {:DOWN, ^worker_down, :process, ^worker, :killed}, @await_ms
      assert_receive {:DOWN, ^tail_down, :process, ^tail, _reason}, @await_ms

      assert lines(stream(worker_id, run_id)) == [{"WorkerStdout", "before the kill"}]
    end

    test "the tail of a cancelled agent is stopped by the worker, not left to end with it", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {worker, agent} = start_agent(worker_id, run_id)

      send(agent.adapter, {:emit, [stdout("before the cancel")]})
      assert [{"WorkerStdout", "before the cancel"}] = await_log_lines(1)

      tail = tail_of(worker)
      tail_down = Process.monitor(tail)

      # Hold the worker inside its exit: its first write there is a call through the Tracker,
      # which does not answer until it is resumed. A tail left to find out for itself would still
      # be running now, because it only ends once the worker has ended.
      :ok = :sys.suspend(Tracker)

      try do
        assert :ok = Jido.Harness.Run.cancel(agent.harness_run_id)
        assert_receive {:DOWN, ^tail_down, :process, ^tail, _reason}, @await_ms
        assert Process.alive?(worker)
      after
        :ok = :sys.resume(Tracker)
      end

      assert_receive {:worker_result, {:error, _reason}}, @await_ms
    end

    test "a tail that crashes costs timeliness only: the worker keeps beating, and the exit writes the rest once",
         %{worker_id: worker_id, run_id: run_id} do
      log =
        capture_log([format: "$metadata$message\n", metadata: [:operation, :run_id]], fn ->
          {worker, agent} = start_agent(worker_id, run_id, heartbeat_interval_ms: 10)
          :ok = Tracker.register(worker_id, run_id, worker)

          send(agent.adapter, {:emit, [stdout("before the crash")]})
          assert [{"WorkerStdout", "before the crash"}] = await_log_lines(1)

          tail = tail_of(worker)
          tail_down = Process.monitor(tail)
          Process.exit(tail, :kill)
          assert_receive {:DOWN, ^tail_down, :process, ^tail, :killed}, @await_ms

          # The worker is alive and answering its timer after the tail is gone...
          await_heartbeats_after(stream_version(worker_id, run_id), 3)
          refute_received {:worker_result, _}

          # ... and from here on nothing delivers output while the agent runs: the stream holds
          # only what was written before the crash, however many heartbeats later.
          send(agent.adapter, {:emit, [stderr("after 1"), stdout("after 2")]})
          await_heartbeats_after(stream_version(worker_id, run_id), 3)
          assert lines(stream(worker_id, run_id)) == [{"WorkerStdout", "before the crash"}]

          send(agent.adapter, :finish)
          assert_receive {:worker_result, {:ok, _text}}, @await_ms
        end)

      # The failure is reported under the operation it belongs to.
      assert log =~ "operation=worker.log_tail"

      # The exit wrote the rest, once, in order, and still ended the stream.
      events = stream(worker_id, run_id)

      assert lines(events) == [
               {"WorkerStdout", "before the crash"},
               {"WorkerStderr", "after 1"},
               {"WorkerStdout", "after 2"}
             ]

      assert List.last(events).event_type == "WorkerExited"
    end
  end

  describe "run_logs, the read model behind foreman_run_get_logs" do
    setup %{run_id: run_id} do
      ProjectionStoreReset.reset!()
      on_exit(&ProjectionStoreReset.reset!/0)

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "RunStarted",
            payload: %{run_id: run_id, task_id: "task-live", project_id: "proj-live"}
          }
        ])

      :ok = ProjectionStore.subscribe(replay_existing: false)
    end

    # The store broadcasts an entry once it has folded it in, and it broadcasts every test's.
    defp await_projected_logs(run_id, count, deadline \\ nil)
    defp await_projected_logs(_run_id, 0, _deadline), do: :ok

    defp await_projected_logs(run_id, count, deadline) do
      deadline = deadline || System.monotonic_time(:millisecond) + @await_ms
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:projection_event, %{event_type: type, data: %{"run_id" => ^run_id}}}
        when type in @log_types ->
          await_projected_logs(run_id, count - 1, deadline)

        {:projection_event, _other} ->
          await_projected_logs(run_id, count, deadline)
      after
        remaining -> flunk("run_logs never received #{count} more line(s) of #{run_id}")
      end
    end

    test "serves the output of a phase that is still running", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {_worker, agent} = start_agent(worker_id, run_id)

      send(agent.adapter, {:emit, [stdout("progress"), stderr("a warning")]})

      # The agent is blocked on `:finish`, which only this test sends.
      await_projected_logs(run_id, 2)

      assert {:ok, %{entries: entries}} = ProjectionStore.run_logs(run_id)

      assert [
               %{channel: "stdout", content: "progress", worker_id: ^worker_id},
               %{channel: "stderr", content: "a warning", worker_id: ^worker_id}
             ] = entries

      refute_received {:worker_result, _}

      send(agent.adapter, :finish)
      assert_receive {:worker_result, {:ok, _text}}, @await_ms
    end
  end
end
