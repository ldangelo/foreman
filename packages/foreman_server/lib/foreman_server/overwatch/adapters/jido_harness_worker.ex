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
    5. The moment the harness run exists (the driver's `:on_start` hook) the
       worker starts a log tail in a process of its own. It follows the run's
       events by cursor and sends the stdout/stderr entries of each page back
       here, one message per page. This worker is the single writer of its
       stream, so `WorkerStdout` / `WorkerStderr` are recorded while the agent
       runs, in the same mailbox as the heartbeats and the terminal events. A
       page is queued and written a slice at a time (`:drain_logs`), so a burst
       of output never holds a heartbeat back for longer than one slice.
    6. The task sends `{:agent_done, result, log_events, meta}` to this pid
       before exiting.
    7. On `:agent_done`, this worker stops the tail, writes what the tail had
       delivered and it had not written yet, then the entries of the finished
       run it has not written yet (`log_cursor`: the harness event
       `sequence`), then `WorkerSessionBound`, `UsageRecorded` and
       `WorkerExited`, and forwards the normalized result to
       `:result_recipient` (the `RunExecutor` pid). Then exits `:normal` so
       `LaunchWorker` sees the DOWN and exits cleanly. It handles no message
       after that, so no log entry can follow `WorkerExited`.

  ## Result normalization

  `RunResult.normalize/1` returns `{:ok, text, metadata}` (3-tuple) for
  success and `{:error, code}` for failure. `RunExecutor.execute_agent`
  pattern-matches on `{:ok, output}` (2-tuple) via
  `with {:ok, output} <- execute_agent(...)`. The Invocation layer
  (`invocation.ex:183`) unwraps the 3-tuple to 2-tuple before forwarding
  to the caller. This worker replicates that unwrap explicitly.
  """

  use GenServer

  require Logger

  alias ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter
  alias ForemanServer.AgentRuntime.JidoHarness.{Driver, ErrorCodes, FailureCause, RunResult}
  alias ForemanServer.Overwatch.{RunMeta, WorkerLogEntry, WorkerLogPolicy, WorkerProtocol}
  alias ForemanServer.RunControl
  alias ForemanServer.Usage
  alias ForemanServer.Workflow.LiveSteer
  alias Jido.Harness.{Run, RunInfo}

  @default_heartbeat_interval_ms 5_000

  # How long the log tail waits before it looks at the harness run again (after a page that was
  # not full, and when it has caught up), and how many events it reads per page. A caught-up
  # round is one cheap `Run.info/1` call (see `read_page/2`), so the period only bounds how late
  # an agent's output can show up in its worker stream.
  @tail_poll_ms 250
  @tail_page_events 500

  # How many log entries the worker writes per mailbox turn. Every write is a call through the
  # Tracker, so a page of hundreds, written in one turn, would hold a heartbeat back for as long
  # as the whole page takes. Between two slices the worker serves whatever else is waiting.
  @log_entries_per_turn 25

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
      project_id: Keyword.get(opts, :project_id),
      task_id: Keyword.get(opts, :task_id),
      secrets: Keyword.get(opts, :secrets, []),
      log_counters: WorkerLogPolicy.initial_counters(),
      # `sequence` of the last harness event whose log entry was handled; see `emit_worker_logs/2`.
      log_cursor: 0,
      # Entries the tail delivered that this worker has not written yet, oldest first; see
      # `:drain_logs`.
      log_backlog: [],
      # The live log tail while the harness run is followed: `%{pid: pid, monitor: reference}`.
      tail: nil
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

    # Spawn the agent in a Task tied to this GenServer's lifetime: `Task.async`
    # links it and this worker does not trap exits, so either one dies with the
    # other.
    parent_pid = self()

    task =
      Task.async(fn ->
        {result, log_events, meta} =
          run_agent(
            parent_pid,
            state.run_id,
            state.provider,
            state.prompt,
            state.driver_opts,
            state.secrets
          )

        send(parent_pid, {:agent_done, result, log_events, meta})
      end)

    Process.monitor(task.pid)

    {:noreply, %{state | activated?: true}}
  end

  def handle_info(:heartbeat, state) do
    _ = WorkerProtocol.emit(:heartbeat, %{worker_id: state.worker_id, run_id: state.run_id})
    Process.send_after(self(), :heartbeat, state.interval)
    {:noreply, state}
  end

  # The harness run exists: follow it. Sent by the agent task's `:on_start` hook, always ahead of
  # that task's `:agent_done` (one sender, one receiver: order is guaranteed).
  def handle_info({:harness_run_started, harness_run_id}, %{tail: nil} = state) do
    {:noreply, %{state | tail: start_tail(harness_run_id)}}
  end

  # One page of log entries from the live tail. Only the current tail is heard. The page joins
  # what is still waiting and is written a slice at a time (`:drain_logs`), never in one go: every
  # write is a call through the Tracker, and a heartbeat that waited out a whole page would be
  # seconds late. What waits lives in this process's state, not in messages it re-sends to
  # itself: a re-sent remainder would queue behind the next page, be handled after it, and be
  # skipped by `log_cursor` as already written.
  def handle_info({:harness_logs, tail_pid, entries}, %{tail: %{pid: tail_pid}} = state) do
    # A `:drain_logs` is queued exactly while entries are waiting.
    if state.log_backlog == [], do: send(self(), :drain_logs)
    {:noreply, %{state | log_backlog: state.log_backlog ++ entries}}
  end

  def handle_info(:drain_logs, state) do
    {slice, rest} = Enum.split(state.log_backlog, @log_entries_per_turn)
    state = %{emit_worker_logs(state, slice) | log_backlog: rest}
    # Queued only now, behind whatever arrived while the slice was written: a heartbeat waits for
    # at most one slice.
    if rest != [], do: send(self(), :drain_logs)
    {:noreply, state}
  end

  def handle_info({:agent_done, result, log_events, meta}, state) do
    # Stop the tail FIRST, then write what it delivered and this worker has not written yet,
    # then whatever it never delivered. Whatever was written is at or behind `log_cursor` and is
    # skipped, so nothing is lost and nothing is written twice. A page still in flight is never
    # heard: this worker stops below, and handles no message after `WorkerExited`, so no log
    # entry can follow it. (The Worker aggregate would not refuse one: `WorkerExited` does not
    # seal a worker stream, only `WorkerCrashed`, `RunCompleted` and `RunFailed` do.)
    state = state |> stop_tail() |> flush_backlog() |> emit_worker_logs(log_events)
    # Ordering matters: the session id is bound BEFORE `:worker_exited` so the
    # worker stream reads in lifecycle order and `Worker.allow_after_terminal/2`
    # (which rejects every non-terminal type on a sealed stream) can never
    # refuse it.
    emit_session_bound(state, meta)
    emit_usage_recorded(state, meta)
    _ = WorkerProtocol.emit(:worker_exited, %{worker_id: state.worker_id, run_id: state.run_id})

    if state.result_recipient do
      send(state.result_recipient, {:worker_result, result})
    end

    {:stop, :normal, state}
  end

  # The tail ended on its own: the harness run is gone (`:normal`), or reading it failed. The
  # finished run's events still carry what the tail did not deliver, so a failed tail costs
  # timeliness (and, past the harness's in-memory event window, older output), never the phase.
  def handle_info({:DOWN, monitor, :process, _pid, reason}, %{tail: %{monitor: monitor}} = state) do
    if reason != :normal do
      Logger.error(
        "JidoHarnessWorker #{state.run_id}: the live log tail stopped (#{inspect(reason)}); " <>
          "the rest of this phase's output is recorded when the agent exits",
        run_id: state.run_id,
        worker_id: state.worker_id,
        operation: "worker.log_tail"
      )
    end

    {:noreply, %{state | tail: nil}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    # The agent task exited normally. It sent `:agent_done` first, so that message is handled
    # ahead of this one. There is no clause for a task that crashed: `Task.async` links it and
    # this worker does not trap exits, so a crashed task takes the worker down with it, and
    # `LaunchWorker` relaunches it.
    {:noreply, state}
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
  @spec run_agent(pid(), String.t(), atom(), String.t(), keyword(), [String.t()]) ::
          {{:ok, String.t()} | ErrorCodes.code() | {:error, FailureCause.t()},
           [WorkerLogEntry.t()], RunMeta.t() | nil}
  defp run_agent(worker, run_id, provider, prompt, driver_opts, secrets) do
    driver_opts =
      Keyword.put(driver_opts, :on_start, fn harness_run_id ->
        RunControl.register_agent(run_id, harness_run_id)
        if LiveSteer.live?(driver_opts), do: LiveSteer.watch(run_id, harness_run_id)
        send(worker, {:harness_run_started, harness_run_id})
      end)

    case Driver.run(provider, prompt, driver_opts) do
      {:ok, %Jido.Harness.RunResult{} = run_result} ->
        LiveSteer.reconcile(run_id, run_result.events)

        {normalize_result(run_result, secrets), log_events(run_result),
         build_meta(provider, run_result)}

      {:ok, detached} when is_map(detached) ->
        harness_run_id = detached[:run_id] || detached["run_id"]
        timeout = Keyword.get(driver_opts, :await_timeout, :infinity)

        case Driver.await(harness_run_id, timeout) do
          {:ok, %Jido.Harness.RunResult{} = run_result} ->
            LiveSteer.reconcile(run_id, run_result.events)

            {normalize_result(run_result, secrets), log_events(run_result),
             build_meta(provider, run_result)}

          {:error, reason} ->
            {JidoHarnessAdapter.normalize_raw_error(reason), [], nil}
        end

      {:error, reason} ->
        {JidoHarnessAdapter.normalize_raw_error(reason), [], nil}
    end
  end

  # Provider-reported facts that `normalize_result/1` discards. Built from the
  # RunResult directly so a FAILED run still yields its session id: a failed
  # run is exactly the one a "fix thread" wants to resume.
  #
  # Public only so `jido_harness_worker_session_test.exs` can exercise it
  # without a provider CLI. Pure and total over any `%RunResult{}`.
  @doc false
  @spec build_meta(atom(), Jido.Harness.RunResult.t()) :: RunMeta.t()
  def build_meta(provider, %Jido.Harness.RunResult{} = run_result) when is_atom(provider) do
    %RunMeta{
      provider: provider,
      provider_session_id: non_empty_binary(run_result.provider_session_id),
      run_status: run_result.status,
      usage: run_result.usage,
      usage_events: Usage.usage_events(run_result.events),
      events_cost_usd: Usage.events_cost_usd(run_result.events)
    }
  end

  defp non_empty_binary(value) when is_binary(value) and value != "", do: value
  defp non_empty_binary(_value), do: nil

  defp emit_session_bound(_state, nil), do: :ok
  defp emit_session_bound(_state, %RunMeta{provider_session_id: nil}), do: :ok

  defp emit_session_bound(state, %RunMeta{provider_session_id: session_id} = meta) do
    payload =
      %{
        worker_id: state.worker_id,
        run_id: state.run_id,
        provider: Atom.to_string(meta.provider),
        provider_session_id: session_id
      }
      |> put_model(Keyword.get(state.driver_opts, :model))
      |> put_approval_mode(Keyword.get(state.driver_opts, :approval_mode))

    _ = WorkerProtocol.emit(:worker_session_bound, payload)
    :ok
  end

  # One `UsageRecorded` per worker run, before `:worker_exited`, for failed
  # runs too (the tokens were spent). Nothing is emitted when the provider
  # reported nothing: an all-nil event would read as "recorded, unknown".
  defp emit_usage_recorded(_state, nil), do: :ok

  defp emit_usage_recorded(state, %RunMeta{} = meta) do
    usage = Usage.from_run(meta.provider, meta.usage, meta.usage_events, meta.events_cost_usd)

    if Usage.empty?(usage) do
      :ok
    else
      payload =
        usage
        |> Usage.to_event_fields()
        |> Map.merge(%{
          worker_id: state.worker_id,
          run_id: state.run_id,
          provider: Atom.to_string(meta.provider),
          project_id: non_empty_binary(state.project_id),
          task_id: non_empty_binary(state.task_id),
          role: "thread",
          run_status: Atom.to_string(meta.run_status),
          at: DateTime.to_iso8601(DateTime.utc_now())
        })
        |> put_model(Keyword.get(state.driver_opts, :model))

      _ = WorkerProtocol.emit(:usage_recorded, payload)
      :ok
    end
  end

  defp put_model(payload, model) when is_binary(model) and model != "",
    do: Map.put(payload, :model, model)

  defp put_model(payload, _model), do: payload

  # The harness approval mode the agent ran with (`RunExecutor.maybe_put_approval_mode/3` puts the
  # atom `:default | :prompt | :auto_edit | :auto_approve` in the driver options; a phase that sets
  # none leaves the key out). Recorded by NAME next to the session it governed: a later agent that
  # resumes that session (a PR fix thread) has to run with the same permissions.
  defp put_approval_mode(payload, mode) when is_atom(mode) and not is_nil(mode),
    do: Map.put(payload, :approval_mode, Atom.to_string(mode))

  defp put_approval_mode(payload, _mode), do: payload

  # Unwrap RunResult.normalize's 3-tuple to the 2-tuple RunExecutor expects.
  # Metadata is dropped here — Invocation drops it for the same reason.
  #
  # A failure keeps the normalized code but also its real cause (message, exit
  # status, timeout kind), redacted: the code alone is `{:other, :execution}`
  # for every killed or failed agent.
  @doc false
  @spec normalize_result(Jido.Harness.RunResult.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, FailureCause.t()}
  def normalize_result(%Jido.Harness.RunResult{} = run_result, secrets) do
    case RunResult.normalize(run_result) do
      {:ok, text, _metadata} -> {:ok, text}
      {:error, code} -> {:error, FailureCause.from_run_result(run_result, code, secrets)}
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
  @spec log_events(term()) :: [WorkerLogEntry.t()]
  def log_events(%Jido.Harness.RunResult{events: events}) when is_list(events),
    do: events_to_logs(events)

  def log_events(_run_result), do: []

  # THE mapping from harness events to log entries. The finished run (`log_events/1`) and the live
  # tail (`tail/4`) both go through it, so the two cannot drift (AGENTS.md 5.7).
  defp events_to_logs(events), do: Enum.flat_map(events, &event_to_log/1)

  # stdout: the CLI mapper turns `ProcessEvent{type: :stdout}` into these
  # three text-bearing types.
  defp event_to_log(%Jido.Harness.Event{type: type, payload: payload} = event)
       when type in [:output_text_delta, :output_text_final, :command_output_delta] and
              is_map(payload) do
    emit_log(:worker_stdout, payload_text(payload), event)
  end

  # stderr does NOT arrive on `:command_output_delta`. The harness routes
  # `ProcessEvent{type: :stderr}` to a `:provider_event` carrying
  # `%{"stream" => "stderr", "data" => data}` — see
  # `adapters/cli_stream.ex:37-38` and `session/transports/pi_rpc.ex:138-140`.
  # Matching only the three text types (and then looking for a `"stream"` key
  # on a payload that is only ever `%{"text" => _}`) made `WorkerStderr`
  # unreachable: every stderr byte was dropped while the tool, the events and
  # the docs all advertised stdout/stderr capture.
  defp event_to_log(
         %Jido.Harness.Event{type: :provider_event, payload: %{"stream" => "stderr"} = payload} =
           event
       ) do
    emit_log(:worker_stderr, Map.get(payload, "data"), event)
  end

  defp event_to_log(_event), do: []

  defp emit_log(_channel, nil, _event), do: []

  defp emit_log(channel, data, %Jido.Harness.Event{timestamp: timestamp, sequence: sequence})
       when is_integer(sequence) and sequence > 0 do
    [%WorkerLogEntry{channel: channel, data: data, timestamp: timestamp, sequence: sequence}]
  end

  # A run numbers its events from 1 (`Jido.Harness.Event.attach/4`); 0 is only the default of an
  # event no run has seen. Such an event is not part of a run's history, and the cursor a line is
  # written by (`emit_worker_logs/2`) would skip it without a word, so it is refused here.
  defp emit_log(_channel, _data, %Jido.Harness.Event{type: type, sequence: sequence}) do
    raise ArgumentError,
          "a harness event of a run carries a positive sequence; got #{inspect(sequence)} on " <>
            "a #{inspect(type)} event"
  end

  defp payload_text(payload) do
    Map.get(payload, "text") || Map.get(payload, "content") || Map.get(payload, "data")
  end

  # The ONE place a log entry is written, for the live tail and for the finished run alike. An
  # entry at or behind `log_cursor` was already handled (the tail delivered it) and is skipped, so
  # a harness event is written exactly once and in sequence order, whichever path delivers it
  # first. Redaction and the line/byte caps (`WorkerLogPolicy`) are applied here, on one set of
  # counters, so they mean the same thing live and at exit.
  defp emit_worker_logs(state, entries) do
    Enum.reduce(entries, state, fn %WorkerLogEntry{sequence: sequence} = entry, acc ->
      if sequence > acc.log_cursor do
        emit_worker_log(%{acc | log_cursor: sequence}, entry)
      else
        acc
      end
    end)
  end

  # Writes what the tail delivered and `:drain_logs` has not written yet.
  defp flush_backlog(%{log_backlog: backlog} = state),
    do: emit_worker_logs(%{state | log_backlog: []}, backlog)

  defp emit_worker_log(state, %WorkerLogEntry{} = entry) do
    case WorkerLogPolicy.normalize(entry.data, state.log_counters, secrets: state.secrets) do
      {:emit, line, counters} ->
        _ =
          WorkerProtocol.emit(entry.channel, %{
            worker_id: state.worker_id,
            run_id: state.run_id,
            line: line,
            timestamp: entry.timestamp
          })

        %{state | log_counters: counters}

      {:drop, _metadata} ->
        state
    end
  end

  # ------------------------------------------------------------------
  # Live log tail
  # ------------------------------------------------------------------

  # The tail is a process of its own, so this worker never blocks on the harness and its heartbeats
  # keep firing. It is MONITORED, not linked: a tail that fails must not take the agent's worker
  # down with it. Every orderly exit goes through `stop_tail/1`; if the worker dies any other way
  # the tail's own monitor fires and it ends itself.
  defp start_tail(harness_run_id) do
    worker = self()

    {pid, monitor} =
      spawn_monitor(fn -> tail(worker, Process.monitor(worker), harness_run_id, 0) end)

    %{pid: pid, monitor: monitor}
  end

  defp stop_tail(%{tail: nil} = state), do: state

  defp stop_tail(%{tail: %{pid: pid, monitor: monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    Process.exit(pid, :kill)
    %{state | tail: nil}
  end

  # Follows the harness run from event `cursor` on and hands the log entries of each page to the
  # worker, which alone writes them: ONE message per page, because the worker's mailbox is shared
  # with its heartbeats and a message per entry would queue hundreds of them ahead. Not
  # `Run.stream/2`: its idle wait is a sleep nothing can interrupt, so a tail built on it would
  # outlive a dead worker, and every idle round of it re-reads the run's journal.
  defp tail(worker, worker_monitor, harness_run_id, cursor) do
    case read_page(harness_run_id, cursor) do
      {:page, events} ->
        case events_to_logs(events) do
          [] -> :ok
          entries -> send(worker, {:harness_logs, self(), entries})
        end

        # A page that is not full held the end of what the run had written: look again a poll
        # period later. After a full page there is probably more waiting.
        wait_ms = if length(events) < @tail_page_events, do: @tail_poll_ms, else: 0
        next_round(worker, worker_monitor, harness_run_id, List.last(events).sequence, wait_ms)

      :caught_up ->
        next_round(worker, worker_monitor, harness_run_id, cursor, @tail_poll_ms)

      # The run no longer exists: nothing more will ever be recorded for it.
      :gone ->
        :ok

      {:error, reason} ->
        exit({:harness_replay_failed, reason})
    end
  end

  # Waits up to `wait_ms` and goes on while the worker is alive.
  defp next_round(worker, worker_monitor, harness_run_id, cursor, wait_ms) do
    receive do
      {:DOWN, ^worker_monitor, :process, _pid, _reason} -> :ok
    after
      wait_ms -> tail(worker, worker_monitor, harness_run_id, cursor)
    end
  end

  # `Run.info/1` is a cheap call into the run process. `Run.replay/2` reads the run's journal from
  # its first line (8 ms for a 1.4 MB journal, measured), so it is only called when the run's
  # `output_cursor` is past ours: an idle agent costs the harness one small call per round.
  @spec read_page(String.t(), non_neg_integer()) ::
          {:page, [Jido.Harness.Event.t(), ...]} | :caught_up | :gone | {:error, term()}
  defp read_page(harness_run_id, cursor) do
    with {:ok, %RunInfo{output_cursor: latest}} when latest > cursor <- Run.info(harness_run_id),
         {:ok, [_ | _] = events} <-
           Run.replay(harness_run_id, cursor: cursor, limit: @tail_page_events) do
      {:page, events}
    else
      {:ok, _nothing_newer} -> :caught_up
      {:error, :not_found} -> :gone
      {:error, reason} -> {:error, reason}
    end
  end
end
