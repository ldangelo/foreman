# Dump the events of the given streams (bindings: streams, width). The event store keeps events
# as Erlang terms, so SQL cannot read `data`; this decodes them on the private server node:
#   devbox run -- bash scripts/e2e/live_claude/rpc.sh \
#     'Code.eval_string(File.read!("/abs/path/events.exs"), streams: ["run:run-abc"], width: 300)'
for uuid <- streams do
  IO.puts("## stream " <> uuid)

  case ForemanServer.EventStore.read_stream_forward(uuid, 0, 1000) do
    {:ok, events} ->
      for ev <- events do
        data = if is_struct(ev.data), do: Map.from_struct(ev.data), else: ev.data
        at = ev.created_at |> DateTime.truncate(:millisecond) |> DateTime.to_time() |> Time.to_string()

        IO.puts(
          "#{at} #{ev.event_type} " <>
            (data |> inspect(limit: 60, printable_limit: width, width: 1000) |> String.slice(0, width))
        )
      end

    other ->
      IO.puts("(unreadable: #{inspect(other)})")
  end
end

:ok
