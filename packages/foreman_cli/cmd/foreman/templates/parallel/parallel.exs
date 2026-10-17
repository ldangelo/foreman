# .foreman/parallel.exs — fan out across N branches concurrently on a running
# foreman_server, then merge each one in turn.
#
# Run with plain Elixir (OTP 27+); no Foreman checkout, no database:
#
#   export FOREMAN_API_TOKEN=...            # the server's bearer token
#   export FOREMAN_PROJECT_ID=my-project    # a project registered on the server
#   export FOREMAN_MERGE_INTO=main          # the branch checked out in the server's copy
#   elixir .foreman/parallel.exs
#
# FOREMAN_API_URL defaults to http://127.0.0.1:4766.
#
# The sandbox image must exist on the SERVER's Docker, built once from that
# project's repo root via:
#   docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) \
#     --build-context ensemble=<your ensemble checkout> \
#     -t "foreman-jobsite:$(basename "$PWD")" .foreman
#
# Merges are **sequential** even though the agents run in parallel: a merge
# changes the server's checkout, so merging concurrently would race. The server
# merges only into the branch it currently has checked out (FOREMAN_MERGE_INTO)
# and refuses otherwise. A conflicting branch is reported and left for a manual
# merge; it does not abort the batch.

# Pin `ref: "<tag or sha>"` here to stop following the default branch.
Mix.install([{:foreman_client, github: "ldangelo/foreman", sparse: "packages/foreman_client"}])

project_id = System.get_env("FOREMAN_PROJECT_ID") || raise "FOREMAN_PROJECT_ID is not set"
into = System.get_env("FOREMAN_MERGE_INTO") || raise "FOREMAN_MERGE_INTO is not set"
client = Foreman.Client.new()

tasks = ["task-a", "task-b", "task-c"]
template = File.read!(Path.join(__DIR__, "prompts/parallel.md"))

# The server takes the prompt as literal text, so `{{TASK}}` is filled in here.
render = fn task -> String.replace(template, "{{TASK}}", task) end
# A raise inside a stream worker is not collected: async_stream links the worker, so
# the exception takes the whole stream down and this script dies with the jobsites
# that already started still running on the server. `catch` turns one into a failure.
start_one = fn task ->
  spec = %{
    "project_id" => project_id,
    "strategy" => %{"branch" => "agent/#{task}"},
    "sandbox" => "docker",
    "agent" => %{
      "provider" => "claude",
      "model" => "claude-sonnet-4-6",
      "approval_mode" => "auto_approve"
    },
    "prompt" => render.(task)
  }

  try do
    Foreman.Client.run(client, spec)
  catch
    kind, reason -> {:error, {:raised, kind, Exception.format(kind, reason, __STACKTRACE__)}}
  end
end

# `timeout:` is per worker, not aggregate: fast items still land on their own arms
# while a slow one is killed (verified: 3 fast workers under `timeout: 700` return
# normally alongside one `{:exit, :timeout}`). `:infinity`, which this used to carry,
# never returns at all -- a hung request blocks the script forever rather than
# reporting a failure. `Foreman.Client.run` drives a jobsite to completion -- create +
# poll -- and `wait` defaults to a one-hour deadline (`timeout_ms` default 3_600_000,
# client.ex:82). So this stream timeout is set just above THAT, not `:httpc`'s 30 s
# per-request ceiling: if set between them, it would kill workers during an ordinary multi-minute
# run and mislabel it `run_timed_out`. `on_timeout: :kill_task` bounds a worker wedged past
# even the hour.

# async_stream is ordered, so result N belongs to task N — including when a worker is
# killed, where the stream yields `{:exit, reason}` with no task to echo. Pairing
# positionally (not by what the worker returned) is what keeps a timeout attributable.
results =
  tasks
  |> Task.async_stream(start_one,
    max_concurrency: length(tasks),
    timeout: 3_700_000,
    on_timeout: :kill_task
  )
  |> Enum.map(fn
    {:ok, outcome} -> outcome
    {:exit, :timeout} -> {:error, :run_timed_out}
    {:exit, why} -> {:error, {:stream_exit, why}}
  end)
  |> then(&Enum.zip(tasks, &1))

for {task, outcome} <- results do
  case outcome do
    {:ok, jobsite} ->
      case Foreman.Client.merge(client, jobsite["jobsite_id"], into) do
        {:ok, _} ->
          IO.puts("merged #{task} (#{jobsite["branch"]})")

        {:error, {409, %{"error" => "merge_conflict"}}} ->
          IO.puts("CONFLICT #{task}: branch #{jobsite["branch"]} left for manual merge")

        {:error, reason} ->
          IO.puts("MERGE FAILED #{task}: #{inspect(reason)}")
      end

    {:error, reason} ->
      IO.puts("FAILED #{task}: #{inspect(reason)}")
  end
end
