# Prints EVERY event of the event store, in global order, one JSON object per line:
#
#     EVIDENCE {"n":41,"stream":"run:run-1","version":3,"at":"2026-10-26T14:49:50.123456Z","type":"RunFailed","data":{...},"meta":{...}}
#
# The post-mortem of a failed harness run (evidence_keep in scripts/e2e/claude_projects/lib.sh, foreman-azc2o): the
# harness drops its database when it exits, so what the run's streams (`run:<id>`: RunStarted .. RunFailed with its
# reason), its worktree (`vcs:wt-<id>`), its phases and the workers' stdout/stderr (`worker:<run id>:<worker id>`) said
# has to be written down first. The database belongs to ONE harness run, so "every event" is that run's own history.
#
# `data` is the payload as the event store holds it (structs become maps, tuples and other terms their `inspect`); text
# longer than 4000 characters (a worker's output line) is cut with an ellipsis, ids and flags never are. An event that
# cannot be encoded is still printed, as {"n":..,"stream":..,"type":..,"error":"encode_failed","detail":..}: a missing
# line would read as "nothing happened".
#
# Evaluated ON THE SERVER NODE by `rpc` (scripts/e2e/claude_projects/lib.sh). Read-only.
limit = 4_000

key = fn
  k when is_binary(k) -> k
  k when is_atom(k) -> Atom.to_string(k)
  k -> inspect(k)
end

cut = fn cut, value ->
  cond do
    is_struct(value, DateTime) -> DateTime.to_iso8601(value)
    is_struct(value) -> cut.(cut, Map.from_struct(value))
    is_map(value) -> Map.new(value, fn {k, v} -> {key.(k), cut.(cut, v)} end)
    is_list(value) -> Enum.map(value, &cut.(cut, &1))
    is_binary(value) and not String.valid?(value) -> inspect(value)
    is_binary(value) and String.length(value) > limit -> String.slice(value, 0, limit) <> "…"
    is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) -> value
    is_atom(value) -> Atom.to_string(value)
    true -> inspect(value)
  end
end

print = fn event ->
  record = %{
    n: event.event_number,
    stream: event.stream_uuid,
    version: event.stream_version,
    at: DateTime.to_iso8601(event.created_at),
    type: event.event_type,
    data: cut.(cut, event.data),
    meta: cut.(cut, event.metadata)
  }

  case Jason.encode(record) do
    {:ok, json} ->
      IO.puts("EVIDENCE " <> json)

    {:error, error} ->
      failed = %{
        n: event.event_number,
        stream: event.stream_uuid,
        type: event.event_type,
        error: "encode_failed",
        detail: inspect(error)
      }

      IO.puts("EVIDENCE " <> Jason.encode!(failed))
  end
end

ForemanServer.EventStore.stream_all_forward(0, read_batch_size: 1_000) |> Enum.each(print)

:ok
