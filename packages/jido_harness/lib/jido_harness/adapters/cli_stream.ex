defmodule Jido.Harness.Adapters.CLIStream do
  @moduledoc false

  alias Jido.Harness.{Adapters.Helpers, Error, ProcessEvent, ProcessManager, RunRequest}

  # `opts[:live_input]` is the list of stdin lines written right after start (the
  # prompt, in streaming-input mode). A live run keeps stdin open so
  # `Jido.Harness.Run.send_input/3` can write more lines later; every other run
  # closes stdin as before.
  def run(provider, %RunRequest{} = request, context, executable, argv, mapper, mapper_state \\ nil, opts \\ []) do
    live_lines = Keyword.get(opts, :live_input)
    stream_end = Keyword.get(opts, :stream_end)

    spec = %{
      executable: executable,
      argv: argv,
      cwd: request.cwd,
      env: request.env,
      env_mode: request.env_mode,
      runtime_timeout_ms: request.runtime_timeout_ms,
      idle_timeout_ms: request.idle_timeout_ms,
      stdin: is_list(live_lines),
      pty: false,
      metadata: %{run_id: context.run_id, provider: provider}
    }

    process_manager = Map.get(context, :process_manager, ProcessManager)

    with {:ok, process_id} <- process_manager.start_owned_process(spec, context.run_owner),
         {:ok, process_stream} <- process_manager.stream_process(process_id),
         :ok <- write_live_lines(process_manager, process_id, live_lines) do
      {:ok, decode(process_stream, provider, mapper, mapper_state, stream_end)}
    end
  end

  defp write_live_lines(_process_manager, _process_id, nil), do: :ok

  defp write_live_lines(process_manager, process_id, lines) do
    Enum.reduce_while(lines, :ok, fn line, :ok ->
      case process_manager.send_input(process_id, line) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, Error.execution("could not write live input", cause: reason)}}
      end
    end)
  end

  # `stream_end` (optional 1-arity fun) is asked what to do once the stream is over and NO
  # run-terminal event was ever seen. A provider CLI can exit 0 after failed turns with no
  # `agent_end`-style record at all — pi does exactly this on exhausted HTTP 429 retries — and
  # without this the run would be recorded `:completed`. The accumulated state names what the
  # stream revealed (see `new_chunk/0`), so a provider can fail such a run loudly.
  #
  # It is a once-per-stream question, so neither the process event nor the stream tail — which for
  # a LIVE run land in an order the harness does not control — can report an outcome twice.
  # `seen_terminal` is what keeps an event from a failed, timed-out or cancelled process, or from
  # any record, from being contradicted by a second answer.
  defp decode(stream, provider, mapper, mapper_state, stream_end) do
    initial = fn -> Map.merge(new_chunk(), %{buffer: "", mapper_state: mapper_state, asked: false}) end

    Stream.transform(
      stream,
      initial,
      fn
        %ProcessEvent{type: :stdout, data: data}, state ->
          {lines, rest} = split_lines(state.buffer <> data)
          map_lines(lines, %{state | buffer: rest}, provider, mapper)

        %ProcessEvent{type: :stderr, data: data}, state ->
          {[Helpers.event(provider, :provider_event, nil, %{"stream" => "stderr", "data" => data})], state}

        %ProcessEvent{type: :failed, data: data}, state ->
          {events, state} = flush(state, provider, mapper)
          {events ++ [Helpers.event(provider, :run_failed, nil, %{"error" => inspect(data)})], state}

        %ProcessEvent{type: :timed_out}, state ->
          {events, state} = flush(state, provider, mapper)
          {events ++ [Helpers.event(provider, :run_failed, nil, %{"error" => "process timed out"})], state}

        %ProcessEvent{type: :cancelled}, state ->
          {events, state} = flush(state, provider, mapper)
          {events ++ [Helpers.event(provider, :run_cancelled, nil, %{"reason" => "cancelled"})], state}

        %ProcessEvent{type: :exited}, state ->
          {events, state} = flush(state, provider, mapper)
          ask_stream_end(events, state, stream_end, provider)

        _event, state ->
          {[], state}
      end,
      fn state ->
        {events, state} = flush(state, provider, mapper)
        ask_stream_end(events, state, stream_end, provider)
      end
    )
  end

  # Asked at most once, and not at all once the run already reported how it ended.
  defp ask_stream_end(events, state, stream_end, provider) do
    if state.asked or state.seen_terminal do
      {events, state}
    else
      {events ++ stream_end_events(stream_end, state, provider), %{state | asked: true}}
    end
  end

  defp stream_end_events(nil, _state, _provider), do: []

  defp stream_end_events(stream_end, state, provider) do
    case stream_end.(Map.take(state, [:turn_outcome, :turn_error, :seen_terminal])) do
      :ok ->
        []

      {:run_failed, message} when is_binary(message) ->
        [Helpers.event(provider, :run_failed, nil, %{"error" => message})]

      other ->
        [Helpers.event(provider, :run_failed, nil, %{"error" => "stream_end returned #{inspect(other)}"})]
    end
  end

  # What the stream has revealed, as the `stream_end` fun sees it. A run cannot both work and fail
  # at once, so these collapse the last assistant turn into one of three states: `:failed` (it
  # reported `stopReason: "error"` with no output, and its error text), `:worked` (it produced
  # output, whatever else it reported), or `:nothing` (no assistant turn reported anything). Each
  # describes only the LAST such turn — a turn that failed mid-run must not fail a run whose later
  # turn worked — and that is why they reset per chunk.
  #
  # A pi turn that fails with no output maps to no canonical event at all (`Pi.map_event/1` has no
  # clause for it), so a provider's own mapper cannot report this; these fields read the raw record
  # instead. They are the contract `Pi.stream_end/1` consumes. `:seen_terminal` is sticky across
  # chunks and means something else already reported how the run ended, which ends the question.
  defp new_chunk, do: %{turn_outcome: :nothing, turn_error: nil, seen_terminal: false}

  defp observe(events, value, state) do
    state
    |> note_terminal(events)
    |> note_turn(value)
  end

  # Any run-terminal event settles how the run ended for good.
  defp note_terminal(state, events) do
    if Enum.any?(events, &Jido.Harness.Event.run_terminal?/1), do: %{state | seen_terminal: true}, else: state
  end

  # pi reports a turn as an assistant `message_end` (json mode) or `turn_end` (rpc mode) record:
  # content blocks when the turn produced anything, else `stopReason: "error"` with an
  # `errorMessage` when the provider call failed, else a plain non-error stop reason. All three
  # report an outcome, so this is where the last one is found — json mode gives no other evidence
  # that a turn was even attempted, and `agent_end` is absent from exactly the streams that matter.
  defp note_turn(state, %{"type" => type, "message" => message} = value)
       when type in ["message_end", "turn_end"] do
    case message_role(value) do
      "assistant" ->
        cond do
          assistant_had_work?(message) -> %{state | turn_outcome: :worked, turn_error: nil}
          get_in(message, ["stopReason"]) == "error" -> %{state | turn_outcome: :failed, turn_error: error_text(message)}
          true -> %{state | turn_outcome: :worked, turn_error: nil}
        end

      # A turn with no assistant message at all (rpc-mode `turn_end` records carry none, and a
      # `message_end` can name another role) reports no outcome of its own, so it must not
      # overwrite the outcome of the failed assistant turn that preceded it.
      _other ->
        state
    end
  end

  defp note_turn(state, _value), do: state

  defp message_role(%{"message" => %{"role" => role}}) when is_binary(role), do: role
  defp message_role(_value), do: nil

  defp error_text(message) do
    case Map.get(message, "errorMessage") do
      error when is_binary(error) and error != "" -> error
      _other -> "assistant turn failed"
    end
  end

  # Text, a tool call, or a tool result: anything but an empty failed turn counts as work.
  defp assistant_had_work?(message) do
    message
    |> Map.get("content", [])
    |> List.wrap()
    |> Enum.any?(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text != ""
      %{"type" => type} when type in ["toolCall", "toolResult"] -> true
      _block -> false
    end)
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp flush(%{buffer: ""} = state, _provider, _mapper), do: {[], state}

  # The undecoded tail of a chunk is not a new window, so it is decoded with the buffer cleared
  # and the reveal window (see `new_chunk/0`) left exactly as the chunk left it.
  defp flush(state, provider, mapper), do: map_lines([state.buffer], %{state | buffer: ""}, provider, mapper)

  defp map_lines(lines, state, provider, mapper) do
    lines
    |> Enum.map_reduce(state, &map_line(&1, &2, provider, mapper))
    |> then(fn {events, state} -> {List.flatten(events), state} end)
  end

  defp map_line(line, state, provider, mapper) do
    line = String.trim(line)

    if line == "" do
      {[], state}
    else
      case Jason.decode(line) do
        {:ok, value} ->
          {events, state} = map_value(mapper, value, state)
          {events, observe(state, events, value)}

        {:error, reason} ->
          {[
             Helpers.event(
               provider,
               :provider_event,
               nil,
               %{"mapped" => false, "decode_error" => Exception.message(reason)},
               line
             )
           ], state}
      end
    end
  rescue
    exception ->
      {[
         Helpers.event(
           provider,
           :run_failed,
           nil,
           %{"error" => Exception.message(exception)},
           Error.execution("CLI event mapping failed", provider: provider, cause: exception)
         )
       ], state}
  end

  defp map_value(mapper, value, state) when is_function(mapper, 2) do
    case mapper.(value, state.mapper_state) do
      {events, mapper_state} -> {List.wrap(events), %{state | mapper_state: mapper_state}}
      events -> {List.wrap(events), state}
    end
  end

  defp map_value(mapper, value, state), do: {List.wrap(mapper.(value)), state}
end
