# Prints the wall-clock interval of one run, read from its event stream (the event store, not the
# projection: the projection's last_event_at_ms moves whenever any later event touches the run):
#
#     <run id> <RunStarted time, epoch ms> <first terminal event time, epoch ms | -> <terminal type | ->
#
# `-` for the finish means the run has no terminal event yet. Evaluated ON THE SERVER NODE by `rpc`
# (scripts/e2e/claude_projects/lib.sh, run_interval in overlap.sh); the caller binds `run_id` first.
# Read-only.
terminal = ~w(RunCompleted RunFailed RunCancelled RunBlocked RunFlaggedStuck)
{:ok, events} = ForemanServer.EventStore.read_stream_forward("run:" <> run_id, 0, 99_999_999)
ms = fn event -> DateTime.to_unix(event.created_at, :millisecond) end

started = Enum.find(events, &(&1.event_type == "RunStarted"))
finished = Enum.find(events, &(&1.event_type in terminal))

IO.puts(
  Enum.join(
    [
      run_id,
      if(started, do: ms.(started), else: "-"),
      if(finished, do: ms.(finished), else: "-"),
      if(finished, do: finished.event_type, else: "-")
    ],
    " "
  )
)

:ok
