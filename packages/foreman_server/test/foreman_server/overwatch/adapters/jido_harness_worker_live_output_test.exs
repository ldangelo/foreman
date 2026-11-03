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
  """

  use ExUnit.Case, async: false

  # A task crash and a worker shutdown are on purpose here: their reports are not output.
  @moduletag :capture_log

  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Overwatch.Adapters.JidoHarnessWorker
  alias ForemanServer.Overwatch.Tracker
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
  defp await_events(done?),
    do: await_events(done?, [], System.monotonic_time(:millisecond) + @await_ms)

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
      %{tail: %{pid: tail}} = :sys.get_state(worker)
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
      assert_receive {:DOWN, ^tail_down, :process, ^tail, :killed}, @await_ms
    end

    test "a line queued behind the agent's result is never written", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {worker, agent} = start_agent(worker_id, run_id)

      send(agent.adapter, {:emit, [stdout("early")]})
      assert [{"WorkerStdout", "early"}] = await_log_lines(1)
      %{tail: %{pid: tail}} = :sys.get_state(worker)

      entry = fn sequence, text ->
        %{
          channel: :worker_stdout,
          data: text,
          timestamp: "2026-11-02T00:00:00Z",
          sequence: sequence
        }
      end

      # While the worker is not running, queue the agent's result and then one more line from the
      # tail: they are handled in the order they were queued, so the line is the late one.
      worker_down = Process.monitor(worker)
      :ok = :sys.suspend(worker)
      send(worker, {:agent_done, {:ok, "done"}, [entry.(1_000, "from the result")], nil})
      send(worker, {:harness_log, tail, entry.(1_001, "too late")})
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

      %{tail: %{pid: tail}} = :sys.get_state(worker)
      tail_down = Process.monitor(tail)
      worker_down = Process.monitor(worker)

      # The harness run process dies under the agent task that is awaiting it: the task exits, and
      # the worker, linked to it, goes with it.
      Process.exit(agent.run, :kill)

      assert_receive {:DOWN, ^worker_down, :process, ^worker, reason}, @await_ms
      assert reason != :normal
      assert_receive {:DOWN, ^tail_down, :process, ^tail, _reason}, @await_ms

      assert lines(stream(worker_id, run_id)) == [{"WorkerStdout", "before the crash"}]
    end

    test "a worker that is shut down takes its tail with it", %{
      worker_id: worker_id,
      run_id: run_id
    } do
      {worker, agent} = start_agent(worker_id, run_id)

      send(agent.adapter, {:emit, [stdout("before the shutdown")]})
      assert [{"WorkerStdout", "before the shutdown"}] = await_log_lines(1)

      %{tail: %{pid: tail}} = :sys.get_state(worker)
      tail_down = Process.monitor(tail)
      worker_down = Process.monitor(worker)

      Process.exit(worker, :shutdown)

      assert_receive {:DOWN, ^worker_down, :process, ^worker, :shutdown}, @await_ms
      assert_receive {:DOWN, ^tail_down, :process, ^tail, _reason}, @await_ms

      assert lines(stream(worker_id, run_id)) == [{"WorkerStdout", "before the shutdown"}]
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
