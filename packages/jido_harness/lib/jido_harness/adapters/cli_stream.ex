defmodule Jido.Harness.Adapters.CLIStream do
  @moduledoc false

  alias Jido.Harness.{Adapters.Helpers, Error, ProcessEvent, ProcessManager, RunRequest}

  # `opts[:live_input]` is the list of stdin lines written right after start (the
  # prompt, in streaming-input mode). A live run keeps stdin open so
  # `Jido.Harness.Run.send_input/3` can write more lines later; every other run
  # closes stdin as before.
  def run(provider, %RunRequest{} = request, context, executable, argv, mapper, mapper_state \\ nil, opts \\ []) do
    live_lines = Keyword.get(opts, :live_input)

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
      {:ok, decode(process_stream, provider, mapper, mapper_state)}
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

  defp decode(stream, provider, mapper, mapper_state) do
    Stream.transform(
      stream,
      fn -> %{buffer: "", mapper_state: mapper_state} end,
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
          flush(state, provider, mapper)

        _event, state ->
          {[], state}
      end,
      fn state -> state |> flush(provider, mapper) |> elem(0) end
    )
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp flush(%{buffer: ""} = state, _provider, _mapper), do: {[], state}
  defp flush(state, provider, mapper), do: map_lines([state.buffer], %{state | buffer: ""}, provider, mapper)

  defp map_lines(lines, state, provider, mapper) do
    Enum.map_reduce(lines, state, fn line, state -> map_line(line, state, provider, mapper) end)
    |> then(fn {events, state} -> {List.flatten(events), state} end)
  end

  defp map_line(line, state, provider, mapper) do
    line = String.trim(line)

    if line == "" do
      {[], state}
    else
      case Jason.decode(line) do
        {:ok, value} ->
          map_value(mapper, value, state)

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
