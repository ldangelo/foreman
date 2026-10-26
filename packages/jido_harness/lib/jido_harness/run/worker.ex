defmodule Jido.Harness.RunWorker do
  @moduledoc false
  use GenServer, restart: :temporary

  alias Jido.Harness.{Adapters.Helpers, Buffer, Error, Event, EventLog, RunInfo, RunResult, TextTail, Waiters}

  # An idle live run with a written-but-unconsumed message waits this long for the
  # provider to take it before stdin is closed anyway (the message then stays
  # unconsumed and the caller sees it as undelivered).
  @live_input_grace_ms 10_000

  # A live run closes its CLI's stdin when the run is over (the provider went idle, or recorded a
  # terminal event) and expects the CLI to exit on the EOF. One that stays alive anyway (a persistent
  # rpc process wedged in its own shutdown) is stopped after this long and the run finishes from what
  # it recorded, so a finished run can never stay open for as long as its CLI chooses to live.
  # Overridable per provider with `live_exit_grace_ms` in `:provider_config`.
  @live_exit_grace_ms 10_000

  def start_link({id, provider, request, adapter, config}) do
    GenServer.start_link(
      __MODULE__,
      {id, provider, request, adapter, config},
      name: {:via, Registry, {Jido.Harness.RunRegistry, id}}
    )
  end

  @impl true
  def init({id, provider, request, adapter, config}) do
    Process.flag(:trap_exit, true)
    retention = Map.get(config, :retention, %{}) |> Map.new()
    memory_bytes = Map.get(retention, :memory_bytes, 1_048_576)
    journal = EventLog.open(id, retention)

    context = %{
      run_id: id,
      provider: provider,
      config: config,
      telemetry_context: %{run_id: id, provider: provider},
      process_manager: Jido.Harness.ProcessManager,
      run_owner: self()
    }

    state = %{
      id: id,
      provider: provider,
      request: request,
      adapter: adapter,
      context: context,
      status: :starting,
      started_at: timestamp(),
      finished_at: nil,
      provider_session_id: request.provider_session_id,
      sequence: 0,
      buffer: EventLog.new_buffer(memory_bytes),
      journal: journal,
      task: nil,
      adapter_started_at: nil,
      runtime_timer: nil,
      runtime_token: nil,
      idle_timer: nil,
      idle_token: nil,
      terminal_event: nil,
      text_tail: TextTail.new(memory_bytes),
      final_text_tail: nil,
      usage: %{},
      error: nil,
      result: nil,
      waiters: %{},
      live: init_live(request, adapter, config)
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    started = Event.new!(%{type: :run_started, provider: state.provider, payload: %{"cwd" => state.request.cwd}})
    state = state |> Map.put(:status, :running) |> append(started)
    owner = self()

    :telemetry.execute([:jido, :harness, :run, :start], %{system_time: System.system_time()}, %{
      run_id: state.id,
      provider: state.provider
    })

    state = %{state | adapter_started_at: System.monotonic_time()}

    :telemetry.execute([:jido, :harness, :adapter, :start], %{system_time: System.system_time()}, %{
      run_id: state.id,
      provider: state.provider,
      adapter: state.adapter
    })

    task =
      Task.Supervisor.async(Jido.Harness.AdapterTaskSupervisor, fn ->
        invoke_adapter(state.adapter, state.request, state.context, owner)
      end)

    {:noreply, state |> Map.put(:task, task) |> schedule_runtime() |> schedule_idle()}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, {:ok, info(state)}, state}

  def handle_call(:result, _from, %{result: %RunResult{} = result} = state), do: {:reply, {:ok, result}, state}
  def handle_call(:result, _from, state), do: {:reply, {:pending, info(state)}, state}

  def handle_call({:await, _request_ref}, _from, %{result: %RunResult{} = result} = state),
    do: {:reply, {:ok, result}, state}

  def handle_call({:await, request_ref}, from, state),
    do: {:noreply, %{state | waiters: Waiters.add(state.waiters, request_ref, from)}}

  def handle_call({:replay, cursor, limit}, _from, state) do
    {records, state} = replay_records(state, cursor, limit)
    {:reply, {:ok, Enum.map(records, &record_to_event(state, &1))}, state}
  end

  def handle_call({:send_input, input_id, text}, _from, state) do
    case send_live_input(state, input_id, text) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:cancel, _from, %{result: %RunResult{}} = state), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, %{terminal_event: %Event{}} = state) do
    state = state |> stop_adapter() |> finalize_from_terminal()
    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, state) when state.status in [:starting, :running] do
    state =
      state
      |> stop_adapter()
      |> append_terminal(:run_cancelled, %{"reason" => "cancelled"})
      |> finalize(:cancelled, nil)

    {:reply, :ok, state}
  end

  def handle_call(:cancel, _from, state), do: {:reply, :ok, state}

  def handle_call(:prune, _from, state) when state.status in [:completed, :failed, :cancelled] do
    EventLog.remove(state.journal)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:prune, _from, state), do: {:reply, {:error, :running}, state}

  @impl true
  def handle_cast({:cancel_await, request_ref}, state),
    do: {:noreply, %{state | waiters: Waiters.cancel(state.waiters, request_ref)}}

  @impl true
  def handle_info({:adapter_event, %Event{} = event}, %{terminal_event: nil} = state) do
    state = schedule_idle(state)

    state =
      if event.provider_session_id,
        do: %{state | provider_session_id: event.provider_session_id},
        else: state

    if event.type == :run_started do
      {:noreply, state}
    else
      event = resolve_live_input(state, event)
      state = append(state, event)
      state = if Event.terminal?(event), do: %{state | terminal_event: event}, else: state
      {:noreply, live_after_event(state, event)}
    end
  end

  def handle_info({:adapter_event, _event}, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | task: nil}

    state =
      case result do
        :ok -> finish_success(state)
        {:error, reason} -> finish_error(state, reason)
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %{ref: ref}} = state) do
    {:noreply, state |> Map.put(:task, nil) |> finish_error(reason)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, %{state | waiters: Waiters.drop_monitor(state.waiters, monitor)}}
  end

  def handle_info({:live_input_grace, token}, %{live: %{idle_token: token}, result: nil} = state)
      when not is_nil(token),
      do: {:noreply, close_live_input(state)}

  # The CLI outlived its closed stdin. It is stopped and the run finishes from what it recorded: the
  # terminal event if there is one, otherwise the idle turn it ended on is a completion. A CLI that
  # did exit has already finished the run (`result` is set), so a late timer never touches one.
  def handle_info({:live_exit_grace, token}, %{live: %{exit_token: token}, result: nil} = state)
      when not is_nil(token) do
    state =
      state
      |> append(
        Event.new!(%{
          type: :provider_event,
          provider: state.provider,
          provider_session_id: state.provider_session_id,
          payload: %{"kind" => "live_exit_grace_expired", "grace_ms" => state.live.exit_grace_ms}
        })
      )
      |> stop_adapter()
      |> finish_success()

    {:noreply, state}
  end

  def handle_info({:run_timeout, :runtime, token}, %{runtime_token: token, status: status} = state)
      when status in [:starting, :running] do
    {:noreply, timeout(state, :runtime)}
  end

  def handle_info({:run_timeout, :idle, token}, %{idle_token: token, status: status} = state)
      when status in [:starting, :running] do
    {:noreply, timeout(state, :idle)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    :ok
  end

  defp invoke_adapter(adapter, request, context, owner) do
    try do
      case adapter.run(request, context) do
        {:ok, stream} ->
          if Enumerable.impl_for(stream) do
            Enum.each(stream, fn
              %Event{} = event -> send(owner, {:adapter_event, event})
              other -> throw({:invalid_adapter_event, other})
            end)

            :ok
          else
            {:error, Error.execution("adapter run/2 did not return an enumerable", provider: context.provider)}
          end

        {:error, reason} ->
          {:error, reason}

        other ->
          {:error,
           Error.execution("adapter returned an invalid result",
             provider: context.provider,
             details: %{value: inspect(other)}
           )}
      end
    rescue
      exception ->
        {:error,
         Error.execution("adapter execution raised",
           provider: context.provider,
           cause: exception,
           details: %{message: Exception.message(exception)}
         )}
    catch
      kind, reason ->
        {:error, Error.execution("adapter execution terminated", provider: context.provider, cause: {kind, reason})}
    end
  end

  # ---------------------------------------------------------------------
  # Streaming input (`provider_options: %{live_input: true}`).
  #
  # The run's CLI stays alive with stdin open after a turn finishes, so more input
  # can be written. All bookkeeping lives in this process, so a write and the
  # decision to close stdin are serialized: either the write lands while the input
  # is open and keeps it open until the provider consumes it, or it is refused
  # with `:input_closed`. Nothing is written into a closed pipe and nothing is
  # lost silently.
  #
  # Such a CLI never exits by itself: closing its stdin is the ONLY way the run ends, so
  # every way a run can end has to close it (`live_after_event/2`): the provider going
  # idle with nothing pending (`:input_idle`), a written message the provider never took
  # (the grace timer), and a TERMINAL event. The last is the easy one to miss: a provider
  # that fails its turn (pi `agent_end` with `stopReason: "error"`, claude `result` with
  # `is_error`) records the terminal event FIRST, and every event after it, `agent_settled`
  # (`:input_idle`) included, is dropped, so the CLI sat idle on an open stdin for ever and
  # `Run.await/2` never returned (a 429 at the end of an otherwise finished phase held a
  # Foreman run `in_progress` until its deadline, with nothing wrong in the worktree).
  # A CLI that outlives its closed stdin is stopped after `@live_exit_grace_ms`.
  # ---------------------------------------------------------------------
  defp init_live(request, adapter, config) do
    options = Helpers.provider_options(request.provider_options, [:live_input])

    if options[:live_input] == true and function_exported?(adapter, :live_input_line, 2),
      do: %{
        pending: [],
        closed?: false,
        idle_token: nil,
        idle_payload: nil,
        exit_token: nil,
        exit_grace_ms: exit_grace_ms!(config)
      },
      else: nil
  end

  defp exit_grace_ms!(config) do
    case Map.get(config, :live_exit_grace_ms, @live_exit_grace_ms) do
      ms when is_integer(ms) and ms > 0 ->
        ms

      other ->
        raise ArgumentError, "provider_config live_exit_grace_ms must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp send_live_input(%{live: nil}, _input_id, _text), do: {:error, :not_live}

  defp send_live_input(%{live: %{closed?: true}}, _input_id, _text), do: {:error, :input_closed}

  defp send_live_input(%{result: %RunResult{}}, _input_id, _text), do: {:error, :not_running}
  defp send_live_input(%{terminal_event: %Event{}}, _input_id, _text), do: {:error, :not_running}
  defp send_live_input(%{status: status}, _input_id, _text) when status != :running, do: {:error, :not_running}

  defp send_live_input(%{live: live} = state, input_id, text) do
    manager = state.context.process_manager

    cond do
      List.keymember?(live.pending, input_id, 0) ->
        {:error, :duplicate_input}

      true ->
        with {:ok, process_id} <- Helpers.live_process_id(manager, state.id),
             :ok <- manager.send_input(process_id, state.adapter.live_input_line(input_id, text)) do
          {:ok, %{state | live: %{live | pending: live.pending ++ [{input_id, text}], idle_token: nil}}}
        else
          {:error, :not_running} -> {:error, :not_running}
          {:error, reason} -> {:error, {:write_failed, reason}}
        end
    end
  end

  # A provider that echoes only text (pi) is matched to the pending input FIFO
  # BEFORE the event is journaled, so every `:input_accepted` a consumer sees
  # names the input it consumed (nil only for the initial prompt's echo).
  defp resolve_live_input(
         %{live: %{pending: pending}},
         %Event{type: :input_accepted, payload: %{"input_id" => nil, "text" => text} = payload} = event
       ) do
    case Enum.find(pending, fn {_id, pending_text} -> pending_text == text end) do
      {input_id, _text} -> %{event | payload: Map.put(payload, "input_id", input_id)}
      nil -> event
    end
  end

  defp resolve_live_input(_state, event), do: event

  defp live_after_event(%{live: nil} = state, _event), do: state

  defp live_after_event(state, %Event{type: :input_accepted, payload: payload}) do
    put_in_live(state, :pending, take_pending(state.live.pending, payload["input_id"], payload["text"]))
  end

  defp live_after_event(%{live: live} = state, %Event{type: :input_idle, payload: payload}) do
    state = %{state | live: %{live | idle_payload: payload}}

    if state.live.pending == [] do
      close_live_input(state)
    else
      token = make_ref()
      Process.send_after(self(), {:live_input_grace, token}, @live_input_grace_ms)
      put_in_live(state, :idle_token, token)
    end
  end

  defp live_after_event(state, %Event{type: type})
       when type in [:turn_started, :tool_call, :output_text_delta, :thinking_delta],
       do: put_in_live(state, :idle_token, nil)

  # A terminal event ends the run whatever the provider does next, and `:input_idle`, the usual
  # trigger, is never delivered after one (`handle_info/2` drops everything past it): the CLI is told
  # to go now, or an rpc process that failed its turn would idle on its open stdin for ever.
  defp live_after_event(state, %Event{} = event) do
    if Event.terminal?(event), do: close_live_input(state), else: state
  end

  # Consumption is matched by input id (resolved from the echoed text first, see
  # `resolve_live_input/2`). An echo that matches nothing (the initial prompt)
  # changes nothing.
  defp take_pending(pending, input_id, _text) when is_binary(input_id),
    do: List.keydelete(pending, input_id, 0)

  defp take_pending(pending, nil, _text), do: pending

  defp close_live_input(%{live: %{closed?: true}} = state), do: state

  # Closing is the only thing that ends a live CLI, so it also starts the clock on the CLI actually
  # going (`{:live_exit_grace, token}` in `handle_info/2`).
  defp close_live_input(state) do
    manager = state.context.process_manager

    with {:ok, process_id} <- Helpers.live_process_id(manager, state.id) do
      _ = manager.close_input(process_id)
    end

    token = make_ref()
    Process.send_after(self(), {:live_exit_grace, token}, state.live.exit_grace_ms)

    state
    |> put_in_live(:closed?, true)
    |> put_in_live(:exit_token, token)
  end

  defp put_in_live(%{live: live} = state, key, value), do: %{state | live: Map.put(live, key, value)}

  defp completion_payload(%{live: %{idle_payload: payload}}) when is_map(payload), do: payload
  defp completion_payload(_state), do: %{}

  defp append(state, %Event{} = event) do
    event = Event.attach(event, state.id, state.provider, state.sequence + 1)
    secrets = Jido.Harness.Redaction.secrets_from_env(state.request.env)
    {buffer, journal} = EventLog.append(state.buffer, state.journal, event, secrets)

    :telemetry.execute([:jido, :harness, :run, :event], %{count: 1}, %{
      run_id: state.id,
      provider: state.provider,
      type: event.type
    })

    state
    |> Map.put(:sequence, event.sequence)
    |> Map.put(:buffer, buffer)
    |> Map.put(:journal, journal)
    |> accumulate(event)
  end

  defp append_terminal(%{terminal_event: %Event{}} = state, _type, _payload), do: state

  defp append_terminal(state, type, payload) do
    event =
      Event.new!(%{
        type: type,
        provider: state.provider,
        provider_session_id: state.provider_session_id,
        payload: payload
      })

    state = append(state, event)
    %{state | terminal_event: event}
  end

  defp accumulate(state, %Event{type: :output_text_delta, payload: payload}) do
    case Map.get(payload, "text") do
      text when is_binary(text) -> %{state | text_tail: TextTail.append(state.text_tail, text)}
      _ -> state
    end
  end

  defp accumulate(state, %Event{type: :output_text_final, payload: payload}) do
    case Map.get(payload, "text") do
      text when is_binary(text) -> %{state | final_text_tail: TextTail.replace(state.text_tail, text)}
      _ -> state
    end
  end

  defp accumulate(state, %Event{type: :usage, payload: payload}), do: %{state | usage: Map.merge(state.usage, payload)}
  defp accumulate(state, _event), do: state

  defp finish_success(%{terminal_event: nil} = state) do
    state |> append_terminal(:run_completed, completion_payload(state)) |> finalize(:completed, nil)
  end

  defp finish_success(%{terminal_event: %{type: :run_completed}} = state), do: finalize(state, :completed, nil)
  defp finish_success(%{terminal_event: %{type: :run_cancelled}} = state), do: finalize(state, :cancelled, nil)
  defp finish_success(%{terminal_event: %{type: :run_failed}} = state), do: finalize_from_terminal(state)

  defp finish_error(%{terminal_event: nil} = state, reason) do
    error = normalize_error(state, reason)
    state |> append_terminal(:run_failed, %{"error" => Exception.message(error)}) |> finalize(:failed, error)
  end

  defp finish_error(%{terminal_event: %Event{}} = state, _reason), do: finalize_from_terminal(state)

  defp finalize(state, status, error) do
    events = Buffer.events(state.buffer)
    text = state.final_text_tail || state.text_tail

    result = %RunResult{
      run_id: state.id,
      provider: state.provider,
      provider_session_id: state.provider_session_id,
      status: status,
      text: text.data,
      text_truncated?: text.truncated?,
      usage: state.usage,
      events: events,
      metadata: state.request.metadata,
      error: error
    }

    cancel_timer(state.runtime_timer)
    cancel_timer(state.idle_timer)
    state = stop_adapter_telemetry(state, status)

    :telemetry.execute([:jido, :harness, :run, :stop], %{count: 1}, %{
      run_id: state.id,
      provider: state.provider,
      status: status
    })

    waiters = Waiters.reply_all(state.waiters, {:ok, result})

    %{
      state
      | status: status,
        error: error,
        finished_at: timestamp(),
        result: result,
        adapter_started_at: nil,
        runtime_timer: nil,
        idle_timer: nil,
        waiters: waiters
    }
  end

  defp normalize_error(state, %Error{} = error) do
    %{error | provider: error.provider || state.provider, run_id: error.run_id || state.id}
  end

  defp normalize_error(state, reason),
    do: Error.execution("provider run failed", provider: state.provider, run_id: state.id, cause: reason)

  defp maybe_native_cancel(state) do
    if function_exported?(state.adapter, :cancel, 2) do
      _ = state.adapter.cancel(state.id, state.context)
    end
  rescue
    _ -> :ok
  end

  defp stop_adapter(state) do
    maybe_native_cancel(state)
    if state.task, do: Task.shutdown(state.task, 5_000)
    %{state | task: nil}
  end

  defp timeout(%{terminal_event: %Event{}} = state, _kind) do
    state |> stop_adapter() |> finalize_from_terminal()
  end

  defp timeout(state, kind) do
    error = Error.new(:timeout, "#{kind} timeout exceeded", provider: state.provider, run_id: state.id)

    state
    |> stop_adapter()
    |> append_terminal(:run_failed, %{"error" => error.message, "timeout" => Atom.to_string(kind)})
    |> finalize(:failed, error)
  end

  defp finalize_from_terminal(%{terminal_event: %Event{type: :run_completed}} = state),
    do: finalize(state, :completed, nil)

  defp finalize_from_terminal(%{terminal_event: %Event{type: :run_cancelled}} = state),
    do: finalize(state, :cancelled, nil)

  defp finalize_from_terminal(%{terminal_event: %Event{type: :run_failed, payload: payload}} = state) do
    message =
      case Map.get(payload, "error") do
        value when is_binary(value) and value != "" -> value
        _value -> "provider reported failure"
      end

    error = state.error || Error.execution(message, provider: state.provider, run_id: state.id)
    finalize(state, :failed, error)
  end

  defp schedule_runtime(%{request: %{runtime_timeout_ms: :infinity}} = state), do: state

  defp schedule_runtime(state) do
    token = make_ref()
    timer = Process.send_after(self(), {:run_timeout, :runtime, token}, state.request.runtime_timeout_ms)
    %{state | runtime_timer: timer, runtime_token: token}
  end

  defp schedule_idle(%{request: %{idle_timeout_ms: :infinity}} = state), do: state

  defp schedule_idle(state) do
    cancel_timer(state.idle_timer)
    token = make_ref()
    timer = Process.send_after(self(), {:run_timeout, :idle, token}, state.request.idle_timeout_ms)
    %{state | idle_timer: timer, idle_token: token}
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: true, info: false)

  defp stop_adapter_telemetry(%{adapter_started_at: nil} = state, _status), do: state

  defp stop_adapter_telemetry(state, status) do
    :telemetry.execute(
      [:jido, :harness, :adapter, :stop],
      %{duration: System.monotonic_time() - state.adapter_started_at},
      %{run_id: state.id, provider: state.provider, adapter: state.adapter, status: status}
    )

    %{state | adapter_started_at: nil}
  end

  defp replay_records(state, cursor, limit) do
    {records, journal, available_from} = EventLog.replay(state.buffer, state.journal, cursor, limit)
    {prepend_gap(records, state, cursor, available_from), %{state | journal: journal}}
  end

  defp prepend_gap(records, _state, cursor, available_from) when cursor >= available_from - 1, do: records

  defp prepend_gap(records, state, _cursor, available_from) do
    gap =
      Event.new!(%{
        type: :provider_event,
        run_id: state.id,
        provider: state.provider,
        provider_session_id: state.provider_session_id,
        sequence: max(1, available_from - 1),
        payload: %{"kind" => "replay_gap", "available_from" => available_from}
      })

    [gap | records]
  end

  defp record_to_event(_state, %Event{} = event), do: event

  defp record_to_event(state, record) do
    Event.new!(%{
      type: existing_atom(record["type"]),
      run_id: record["run_id"] || state.id,
      provider: existing_atom(record["provider"] || Atom.to_string(state.provider)),
      provider_session_id: record["provider_session_id"],
      turn_id: record["turn_id"],
      request_id: record["request_id"],
      sequence: record["sequence"],
      timestamp: record["timestamp"],
      payload: record["payload"] || %{},
      raw: nil
    })
  end

  defp existing_atom(value) when is_atom(value), do: value
  defp existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp info(state) do
    %RunInfo{
      run_id: state.id,
      provider: state.provider,
      state: state.status,
      started_at: state.started_at,
      finished_at: state.finished_at,
      provider_session_id: state.provider_session_id,
      error: state.error,
      journal_dir: EventLog.dir(state.journal),
      output_cursor: state.sequence,
      metadata: state.request.metadata
    }
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
