# Prints the PR-fix events of one run, the events of its primary worktree (where the run's agent worked) and the events of
# every fix jobsite the PR fixes started, as one JSON object per line:
#
#     EVIDENCE {"stream":"run:<id>","index":12,"at":"2026-10-26T14:49:50.123456Z","type":"PrFixStarted","data":{...}}
#
# `data` is the event payload exactly as the event store holds it (the fields the claude PR-fix stage asserts are
# `PrFixStarted.resumed_session`, `WorktreeCreated.worktree_path`, `JobsiteWorktreeProvisioned.path`,
# `JobsiteStarted.agent`, `JobsiteIterationStarted.resumed_session_id` and `JobsiteIterationCompleted.session_id`). Text
# longer than 400 characters (an agent's final message) is cut so a line stays readable; ids and flags never are.
#
# Evaluated ON THE SERVER NODE by `rpc` (scripts/e2e/claude_projects/lib.sh); the caller binds `run_id` first. Read-only.
fix_events = ~r/^PrFix/

jobsite_events =
  ~w(JobsiteStarted JobsiteWorktreeProvisioned JobsiteIterationStarted JobsiteSessionBound JobsiteIterationCompleted
     JobsiteIterationFailed JobsiteCommitsRecorded JobsiteCompleted JobsiteFailed JobsiteCancelled)

cut = fn cut, value ->
  cond do
    is_struct(value, DateTime) -> DateTime.to_iso8601(value)
    is_struct(value) -> cut.(cut, Map.from_struct(value))
    is_map(value) -> Map.new(value, fn {k, v} -> {if(is_atom(k), do: Atom.to_string(k), else: k), cut.(cut, v)} end)
    is_list(value) -> Enum.map(value, &cut.(cut, &1))
    is_binary(value) and not String.valid?(value) -> inspect(value)
    is_binary(value) and String.length(value) > 400 -> String.slice(value, 0, 400) <> "…"
    is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) -> value
    is_atom(value) -> Atom.to_string(value)
    true -> inspect(value)
  end
end

print = fn stream, events, keep ->
  for {event, index} <- Enum.with_index(events), keep.(event.event_type) do
    line =
      Jason.encode!(%{
        stream: stream,
        index: index,
        at: DateTime.to_iso8601(event.created_at),
        type: event.event_type,
        data: cut.(cut, event.data)
      })

    IO.puts("EVIDENCE " <> line)
  end
end

{:ok, run_stream} = ForemanServer.EventStore.read_stream_forward("run:" <> run_id, 0, 99_999_999)
print.("run:" <> run_id, run_stream, &Regex.match?(fix_events, &1))

# the run's own worktree (one per run: operation id "wt-" <> run_id) lives on a vcs stream, not on the run's
case ForemanServer.EventStore.read_stream_forward("vcs:wt-" <> run_id, 0, 99_999_999) do
  {:ok, events} -> print.("vcs:wt-" <> run_id, events, &(&1 in ~w(WorktreeCreated WorktreeCleaned)))
  _unreadable -> :ok
end

jobsite_ids =
  for event <- run_stream,
      event.event_type == "PrFixStarted",
      id = ForemanServer.Aggregate.get(event.data, :jobsite_id),
      is_binary(id),
      do: id

for id <- Enum.uniq(jobsite_ids) do
  case ForemanServer.EventStore.read_stream_forward("jobsite:" <> id, 0, 99_999_999) do
    {:ok, events} -> print.("jobsite:" <> id, events, &(&1 in jobsite_events))
    _unreadable -> :ok
  end
end

:ok
