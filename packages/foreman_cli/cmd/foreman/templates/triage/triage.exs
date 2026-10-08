# .foreman/triage.exs — pull ready beads from inside the sandbox and work
# one of them.
#
# Run from a Foreman checkout with Postgres up (`devbox run up`):
#   cd packages/foreman_server && mix run ../../.foreman/triage.exs
#
# Plain `mix run` — no `--no-start`. The app must be booted: every Jobsite
# state transition dispatches through `ForemanServer.CommandGateway`, which
# needs Postgres.
#
# Requires the sandbox image built once from the repo root via:
#   docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) \
#     -t "foreman-jobsite:$(basename "$PWD")" .foreman
#
# Requires `br` (beads_rust) to be available inside the sandbox image and a
# `.beads/` database in the target repo.

alias ForemanServer.Jobsite
alias ForemanServer.Jobsite.{Agents, Sandboxes, Sandbox}

repo_path = Path.expand("..", __DIR__)

{:ok, sandbox} =
  Jobsite.create_sandbox(
    repo_path: repo_path,
    strategy: {:branch, "agent/triage"},
    sandbox: Sandboxes.docker()
  )

{:ok, ready} = Sandbox.exec(sandbox, "br ready --json")

case Jason.decode!(ready.stdout) do
  [] ->
    IO.puts("nothing ready")

  [bead | _] ->
    prompt =
      "Implement bead #{bead["id"]}:\n#{bead["title"]}\n#{bead["description"]}\n\n" <>
        "When genuinely complete, end your final message with exactly:\n<promise>COMPLETE</promise>"

    {:ok, _} =
      Sandbox.run(sandbox,
        agent: Agents.claude("claude-opus-4-8", approval_mode: :auto_approve),
        prompt: prompt,
        max_iterations: 5
      )

    {:ok, _} = Sandbox.exec(sandbox, "br close #{bead["id"]} --reason 'Implemented by jobsite'")
end

{:ok, _} = Sandbox.close(sandbox)
