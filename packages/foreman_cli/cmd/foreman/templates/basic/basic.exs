# .foreman/basic.exs — one agent, one iteration, on a running foreman_server.
#
# Run with plain Elixir (OTP 27+); no Foreman checkout, no database:
#
#   export FOREMAN_API_TOKEN=...            # the server's bearer token
#   export FOREMAN_PROJECT_ID=my-project    # a project registered on the server
#   elixir .foreman/basic.exs
#
# FOREMAN_API_URL defaults to http://127.0.0.1:4766.
#
# The agent runs on the SERVER, in the server's checkout of the project, on a
# new branch; this script only sends the spec and waits. This template uses the
# `host` sandbox, which the server refuses unless its operator enabled it
# (`config :foreman_server, :jobsites, allow_host_sandbox: true`). Leave
# "sandbox" out to use the default, `docker`.

# Pin `ref: "<tag or sha>"` here to stop following the default branch.
Mix.install([{:foreman_client, github: "ldangelo/foreman", sparse: "packages/foreman_client"}])

project_id = System.get_env("FOREMAN_PROJECT_ID") || raise "FOREMAN_PROJECT_ID is not set"
client = Foreman.Client.new()

spec = %{
  "project_id" => project_id,
  "strategy" => %{"branch" => "agent/basic"},
  "sandbox" => "host",
  "agent" => %{"provider" => "claude", "model" => "claude-sonnet-4-6", "approval_mode" => "auto_edit"},
  "prompt" => File.read!(Path.join(__DIR__, "prompts/basic.md"))
}

case Foreman.Client.run(client, spec) do
  {:ok, jobsite} ->
    IO.puts("branch=#{jobsite["branch"]} commits=#{length(jobsite["commits"] || [])}")

  {:error, reason} ->
    IO.puts(:stderr, "jobsite did not complete: #{inspect(reason)}")
    System.halt(1)
end
