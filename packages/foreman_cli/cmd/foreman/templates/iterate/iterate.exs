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
# Optional:
#   FOREMAN_AGENT_MODEL=<model>        agent model (default claude-opus-4-8)
#   FOREMAN_AGENT_ENV=A,B              names of variables in THIS shell to pass to the
#                                      agent as agent.env (e.g. ANTHROPIC_BASE_URL,ANTHROPIC_API_KEY);
#                                      the server must allowlist them via
#                                      FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST
#   FOREMAN_MAX_ITERATIONS=<n>         turn limit (default 20)
#
# The sandbox image must exist on the SERVER's Docker, built once from that
# project's repo root via:
#   docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) \
#     --build-context ensemble=<your ensemble checkout> \
#     -t "foreman-jobsite:$(basename "$PWD")" .foreman

# Pin `ref: "<tag or sha>"` here to stop following the default branch.
Mix.install([{:foreman_client, github: "ldangelo/foreman", sparse: "packages/foreman_client"}])

project_id = System.get_env("FOREMAN_PROJECT_ID") || raise "FOREMAN_PROJECT_ID is not set"
client = Foreman.Client.new()

agent_env =
  "FOREMAN_AGENT_ENV"
  |> System.get_env("")
  |> String.split(",", trim: true)
  |> Map.new(fn name ->
    name = String.trim(name)
    {name, System.get_env(name) || raise("#{name} is listed in FOREMAN_AGENT_ENV but is not set")}
  end)

agent = %{
  "provider" => "claude",
  "model" => System.get_env("FOREMAN_AGENT_MODEL", "claude-opus-4-8"),
  "approval_mode" => "auto_approve"
}

agent = if agent_env == %{}, do: agent, else: Map.put(agent, "env", agent_env)

spec = %{
  "project_id" => project_id,
  "strategy" => %{"branch" => "agent/iterate"},
  "sandbox" => "docker",
  "agent" => agent,
  "prompt" => File.read!(Path.join(__DIR__, "prompts/iterate.md")),
  "max_iterations" => String.to_integer(System.get_env("FOREMAN_MAX_ITERATIONS", "20")),
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
