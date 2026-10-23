# Prints the PR, merge-gate and lifecycle events of one run stream, in stream order, one per line:
#
#     <stream index> <UTC time> <event type> key=value ...
#
# Evaluated ON THE SERVER NODE by `rpc` (scripts/e2e/claude_projects/lib.sh); the caller binds
# `run_id` first. Read-only.
keep = ~r/^(Run(Started|Completed|Failed)$|Pr|Merge)/
fields = ~w(head_sha trigger kind attempt outcome reason checks_state review_decision status approver jobsite_id pr_url)a
printable? = fn v -> is_binary(v) or is_number(v) or is_atom(v) end

{:ok, events} = ForemanServer.EventStore.read_stream_forward("run:" <> run_id, 0, 99_999_999)

for {event, index} <- Enum.with_index(events), Regex.match?(keep, event.event_type) do
  pairs =
    for field <- fields,
        value = ForemanServer.Aggregate.get(event.data, field),
        printable?.(value) do
      text = value |> to_string() |> String.replace(~r{^https://github\.com/}, "") |> String.slice(0, 48)
      "#{field}=#{if field == :head_sha, do: String.slice(text, 0, 8), else: text}"
    end

  at = event.created_at |> DateTime.to_time() |> Time.truncate(:second) |> Time.to_string()
  IO.puts(Enum.join(["#{index}", at, event.event_type | pairs], " "))
end

:ok
