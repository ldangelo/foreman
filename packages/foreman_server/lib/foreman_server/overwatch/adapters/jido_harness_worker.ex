defmodule ForemanServer.Overwatch.Adapters.JidoHarnessWorker do
  @moduledoc """
  Worker GenServer that runs a `Jido.Harness` agent under Overwatch supervision.
  Closes the LGC-T002/JHA-T002 gap between `RunExecutor` (which only knew
  about `AgentRuntime.execute`) and the Overwatch supervision tree (sole
  producer of `WorkerStarted` / `WorkerHeartbeat` / `WorkerExited`).

  ## Lifecycle

    1. `LaunchWorker` calls `WorkerProtocol.start_worker/3`, which dispatches
       to `JidoHarnessAdapter.start_link/1` (the adapter contract). This
       module's `start_link/1` is the entry point.
    2. `init/1` captures opts and returns immediately — no blocking work.
    3. `LaunchWorker` sends `{:overwatch_activate, worker_id, run_id, parent}`.
       This worker must reply with `{:overwatch_activated, self()}` within
       `activation_timeout_ms` (default 5_000) or `LaunchWorker` exits.
    4. After the activation ack, the worker spawns the agent in a Task and
       monitors the task pid. The task body calls `Driver.run` (handling
       sync and detached branches) and normalizes via `RunResult.normalize/1`.
    5. The task sends `{:agent_done, result}` to this pid before exiting.
    6. On `:agent_done`, this worker emits `WorkerExited` and forwards the
       normalized result to `:result_recipient` (the `RunExecutor` pid).
       Then exits `:normal` so `LaunchWorker` sees the DOWN and exits cleanly.

  ## Result normalization

  `RunResult.normalize/1` returns `{:ok, text, metadata}` (3-tuple) for
  success and `{:error, code}` for failure. `RunExecutor.execute_agent`
  pattern-matches on `{:ok, output}` (2-tuple) via
  `with {:ok, output} <- execute_agent(...)`. The Invocation layer
  (`invocation.ex:183`) unwraps the 3-tuple to 2-tuple before forwarding
  to the caller. This worker replicates that unwrap explicitly.
  """

  use GenServer

  alias ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter
  alias ForemanServer.AgentRuntime.JidoHarness.{Driver, ErrorCodes, RunResult}
  alias ForemanServer.Overwatch.{WorkerLogPolicy, WorkerProtocol}

  @default_heartbeat_interval_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    worker_id = Keyword.fetch!(opts, :worker_id)
    run_id = Keyword.fetch!(opts, :run_id)
    provider = Keyword.fetch!(opts, :provider)
    prompt = Keyword.fetch!(opts, :prompt)
    driver_opts = put_env(Keyword.get(opts, :driver_opts, []), opts)
    interval = Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)
    result_recipient = Keyword.get(opts, :result_recipient)

    state = %{
      worker_id: worker_id,
      run_id: run_id,
      provider: provider,
      prompt: prompt,
      driver_opts: driver_opts,
      interval: interval,
      result_recipient: result_recipient,
      activated?: false,
      secrets: Keyword.get(opts, :secrets, []),
      log_counters: WorkerLogPolicy.initial_counters()
    }

    {:ok, state}
  end

  # `Overwatch.start_phase/2` computes the worker's env map and forwards it
  # to the adapter as `:env_map` (see `overwatch.ex:124`); every
  # `FOREMAN_*` export RunExecutor produces in `foreman_env/3` arrives here
  # and nowhere else. Until this hop existed the map was read by nothing:
  # `FOREMAN_ARTIFACT_PATH`, `FOREMAN_PRD_PATH`, `FOREMAN_TRD_PATH`,
  # `BEADS_DB` and `TRD_SCOPE` were all unset at the agent, which is why
  # run-d6cdefe69706087e6bce5b1a10b95384 reported `FOREMAN_PRD_PATH:
  # unset/empty` while obeying the contract that names it.
  #
  # `Jido.Harness.Run.Request` accepts `env` (`%{String.t() => term()}`)
  # with `env_mode` defaulting to `:overlay`, threaded through the pi
  # adapter and `Process.Spec` to erlexec, so these keys overlay the
  # ambient environment rather than replacing it.
  #
  # Absent and empty are both "nothing to inject". A non-map means a
  # caller bypassed the `Overwatch` boundary — a programming error, so it
  # raises rather than launching an agent with a silently dropped env.
  defp put_env(driver_opts, opts) do
    case Keyword.get(opts, :env_map) do
      nil ->
        driver_opts

      env when is_map(env) and map_size(env) == 0 ->
        driver_opts

      env when is_map(env) ->
        Keyword.put(driver_opts, :env, env)

      other ->
        raise ArgumentError,
              "JidoHarnessWorker expects :env_map to be a map, got: #{inspect(other)}"
    end
  end

  @impl true
  def handle_info({:overwatch_activate, _worker_id, _run_id, parent}, state) do
    # Activation handshake MUST reply before any blocking work. LaunchWorker
    # enforces a 5s timeout on this reply.
    send(parent, {:overwatch_activated, self()})

    # Schedule periodic heartbeat. First tick fires after `interval`, not
    # immediately — WorkerStarted is LaunchWorker's responsibility.
    Process.send_after(self(), :heartbeat, state.interval)

    # Spawn the agent in a Task tied to this GenServer's lifetime via
    # Process.monitor. When the worker dies, the Task is killed.
    parent_pid = self()

    task =
      Task.async(fn ->
        {result, log_events} = run_agent(state.provider, state.prompt, state.driver_opts)
        send(parent_pid, {:agent_done, result, log_events})
      end)

    Process.monitor(task.pid)

    {:noreply, %{state | activated?: true}}
  end

  def handle_info(:heartbeat, state) do
    _ = WorkerProtocol.emit(:heartbeat, %{worker_id: state.worker_id, run_id: state.run_id})
    Process.send_after(self(), :heartbeat, state.interval)
    {:noreply, state}
  end

  def handle_info({:agent_done, result, log_events}, state) do
    state = emit_worker_logs(state, log_events)
    _ = WorkerProtocol.emit(:worker_exited, %{worker_id: state.worker_id, run_id: state.run_id})

    if state.result_recipient do
      send(state.result_recipient, {:worker_result, result})
    end

    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    # Monitor fired before/after `:agent_done` arrived. Either is benign —
    # `:agent_done` has already been delivered (or will be). Stay alive until
    # it arrives; if it never does, caller-side timeout will surface.
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    # Task crashed without sending :agent_done. Best-effort WorkerExited +
    # surface the failure to the recipient so RunExecutor does not block
    # forever waiting for a result.
    _ = WorkerProtocol.emit(:worker_exited, %{worker_id: state.worker_id, run_id: state.run_id})

    if state.result_recipient do
      send(state.result_recipient, {:worker_result, {:error, {:task_crashed, reason}}})
    end

    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Internals
  # ------------------------------------------------------------------

  # Run the agent, handling both sync and detached cases. Normalize to
  # 2-tuple (matches Invocation.run_attempts/5 at invocation.ex:183):
  #
  #   {:ok, content} | {:error, code}
  #
  # A raw `Driver` failure reason is a bare atom or a
  # `%Jido.Harness.Error{}`, neither of which RunExecutor can interpret;
  # returning it verbatim was how this path reported a failure category it
  # already had. `JidoHarnessAdapter.normalize_raw_error/1` is the single
  # site that reads it, shared with the non-Overwatch adapter so the two
  # cannot drift.
  @spec run_agent(atom(), String.t(), keyword()) ::
          {{:ok, String.t()} | ErrorCodes.code(), [map()]}
  defp run_agent(provider, prompt, driver_opts) do
    case Driver.run(provider, prompt, driver_opts) do
      {:ok, %Jido.Harness.RunResult{} = run_result} ->
        {normalize_result(run_result), log_events(run_result)}

      {:ok, detached} when is_map(detached) ->
        run_id = detached[:run_id] || detached["run_id"]
        timeout = Keyword.get(driver_opts, :await_timeout, :infinity)

        case Driver.await(run_id, timeout) do
          {:ok, %Jido.Harness.RunResult{} = run_result} ->
            {normalize_result(run_result), log_events(run_result)}

          {:error, reason} ->
            {JidoHarnessAdapter.normalize_raw_error(reason), []}
        end

      {:error, reason} ->
        {JidoHarnessAdapter.normalize_raw_error(reason), []}
    end
  end

  # Unwrap RunResult.normalize's 3-tuple to the 2-tuple RunExecutor expects.
  # Metadata is dropped here — Invocation drops it for the same reason.
  defp normalize_result(%Jido.Harness.RunResult{} = run_result) do
    case RunResult.normalize(run_result) do
      {:ok, text, _metadata} -> {:ok, text}
      {:error, _} = err -> err
    end
  end

  # Map a harness run's event log onto the two durable channels.
  #
  # `Jido.Harness.Event` payloads are STRING-KEYED — the struct's own
  # moduledoc says so (`deps/jido_harness/lib/jido_harness/event.ex:6`) and
  # every producer builds `%{"text" => text}` (`adapters/pi.ex:316`,
  # `adapters/json_mapper.ex:51`), which is also how the library's own
  # consumers read them (`session/event_store.ex:83`). Reading the string key
  # directly is therefore the contract, not a guess (AGENTS.md 5.4/5.6): the
  # atom/string dual lookup this replaced was the prohibited "one clause is
  # always dead" hedge, and it wrapped `String.to_existing_atom/1` in a
  # `rescue` on top of that.
  # Public only so `jido_harness_worker_log_capture_test.exs` can pin the
  # upstream event contract this depends on (AGENTS.md 5.6). Pure function:
  # RunResult in, channel-tagged log entries out.
  @doc false
  @spec log_events(term()) :: [%{channel: atom(), data: String.t(), timestamp: term()}]
  def log_events(%Jido.Harness.RunResult{events: events}) when is_list(events) do
    events
    |> Enum.flat_map(&event_to_log/1)
  end

  def log_events(_run_result), do: []

  # stdout: the CLI mapper turns `ProcessEvent{type: :stdout}` into these
  # three text-bearing types.
  defp event_to_log(%Jido.Harness.Event{type: type, payload: payload, timestamp: timestamp})
       when type in [:output_text_delta, :output_text_final, :command_output_delta] and
              is_map(payload) do
    emit_log(:worker_stdout, payload_text(payload), timestamp)
  end

  # stderr does NOT arrive on `:command_output_delta`. The harness routes
  # `ProcessEvent{type: :stderr}` to a `:provider_event` carrying
  # `%{"stream" => "stderr", "data" => data}` — see
  # `adapters/cli_stream.ex:37-38` and `session/transports/pi_rpc.ex:138-140`.
  # Matching only the three text types (and then looking for a `"stream"` key
  # on a payload that is only ever `%{"text" => _}`) made `WorkerStderr`
  # unreachable: every stderr byte was dropped while the tool, the events and
  # the docs all advertised stdout/stderr capture.
  defp event_to_log(%Jido.Harness.Event{
         type: :provider_event,
         payload: %{"stream" => "stderr"} = payload,
         timestamp: timestamp
       }) do
    emit_log(:worker_stderr, Map.get(payload, "data"), timestamp)
  end

  defp event_to_log(_event), do: []

  defp emit_log(_channel, nil, _timestamp), do: []

  defp emit_log(channel, data, timestamp) do
    [%{channel: channel, data: data, timestamp: timestamp}]
  end

  defp payload_text(payload) do
    Map.get(payload, "text") || Map.get(payload, "content") || Map.get(payload, "data")
  end

  defp emit_worker_logs(state, log_events) do
    Enum.reduce(log_events, state, fn log_event, acc ->
      case WorkerLogPolicy.normalize(log_event.data, acc.log_counters, secrets: acc.secrets) do
        {:emit, line, counters} ->
          _ =
            WorkerProtocol.emit(log_event.channel, %{
              worker_id: acc.worker_id,
              run_id: acc.run_id,
              line: line,
              timestamp: log_event.timestamp
            })

          %{acc | log_counters: counters}

        {:drop, _metadata} ->
          acc
      end
    end)
  end
end
