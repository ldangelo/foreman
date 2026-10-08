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
#     -t "foreman-jobsite:$(basename "$PWD")" .foreman
#
# Merges are **sequential** even though the agents run in parallel: a merge
# changes the server's checkout, so merging concurrently would race. The server
# merges only into the branch it currently has checked out (FOREMAN_MERGE_INTO)
# and refuses otherwise. A conflicting branch is reported and left for a manual
# merge; it does not abort the batch.

Code.require_file("foreman_client.exs", __DIR__)

project_id = System.get_env("FOREMAN_PROJECT_ID") || raise "FOREMAN_PROJECT_ID is not set"
into = System.get_env("FOREMAN_MERGE_INTO") || raise "FOREMAN_MERGE_INTO is not set"
client = Foreman.Client.new()

tasks = ["task-a", "task-b", "task-c"]
template = File.read!(Path.join(__DIR__, "prompts/parallel.md"))

# The server takes the prompt as literal text, so `{{TASK}}` is filled in here.
render = fn task -> String.replace(template, "{{TASK}}", task) end

results =
  tasks
  |> Task.async_stream(
    fn task ->
      spec = %{
        "project_id" => project_id,
        "strategy" => %{"branch" => "agent/#{task}"},
        "sandbox" => "docker",
        "agent" => %{"provider" => "claude", "model" => "claude-sonnet-4-6", "approval_mode" => "auto_approve"},
        "prompt" => render.(task)
      }

      {task, Foreman.Client.run(client, spec)}
    end,
    max_concurrency: 3,
    timeout: :infinity
  )
  |> Enum.map(fn {:ok, pair} -> pair end)

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
