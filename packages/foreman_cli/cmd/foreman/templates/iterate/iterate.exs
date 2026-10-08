# .foreman/iterate.exs — one agent, looping until it signals completion
# (bounded by max_iterations), in a Docker sandbox on a running foreman_server.
#
# Run with plain Elixir (OTP 27+); no Foreman checkout, no database:
#
#   export FOREMAN_API_TOKEN=...            # the server's bearer token
#   export FOREMAN_PROJECT_ID=my-project    # a project registered on the server
#   elixir .foreman/iterate.exs
#
# FOREMAN_API_URL defaults to http://127.0.0.1:4766.
#
# The sandbox image must exist on the SERVER's Docker, built once from that
# project's repo root via:
#   docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) \
#     -t "foreman-jobsite:$(basename "$PWD")" .foreman

Code.require_file("foreman_client.exs", __DIR__)

project_id = System.get_env("FOREMAN_PROJECT_ID") || raise "FOREMAN_PROJECT_ID is not set"
client = Foreman.Client.new()

spec = %{
  "project_id" => project_id,
  "strategy" => %{"branch" => "agent/iterate"},
  "sandbox" => "docker",
  "agent" => %{"provider" => "claude", "model" => "claude-opus-4-8", "approval_mode" => "auto_approve"},
  "prompt" => File.read!(Path.join(__DIR__, "prompts/iterate.md")),
  "max_iterations" => 5,
  "completion_signal" => "<promise>COMPLETE</promise>"
}

case Foreman.Client.run(client, spec) do
  {:ok, jobsite} ->
    IO.puts(
      "branch=#{jobsite["branch"]} iterations=#{length(jobsite["iterations"] || [])} status=#{jobsite["status"]}"
    )

  {:error, reason} ->
    IO.puts(:stderr, "jobsite did not complete: #{inspect(reason)}")
    System.halt(1)
end
