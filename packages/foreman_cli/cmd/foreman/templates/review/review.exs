# .foreman/review.exs — implement, then feed real test failures back to the
# agent until green or the retry budget is exhausted.
#
# Run from a Foreman checkout with Postgres up (`devbox run up`):
#   cd packages/foreman_server && mix run ../../.foreman/review.exs
#
# Plain `mix run` — no `--no-start`. The app must be booted: every Jobsite
# state transition dispatches through `ForemanServer.CommandGateway`, which
# needs Postgres.
#
# Requires the sandbox image built once from the repo root via:
#   docker build --build-arg AGENT_UID=$(id -u) --build-arg AGENT_GID=$(id -g) \
#     -t "foreman-jobsite:$(basename "$PWD")" .foreman
#
# The test verdict comes from the host running `mix test` inside the
# sandbox and checking its real exit code — not from the agent's own
# say-so — so a single sandbox is kept open across every attempt via
# `Jobsite.Sandbox.run/2` rather than going through separate `Jobsite.run/1`
# calls.

alias ForemanServer.Jobsite
alias ForemanServer.Jobsite.{Agents, Sandboxes, Sandbox}

repo_path = Path.expand("..", __DIR__)

{:ok, sandbox} =
  Jobsite.create_sandbox(
    repo_path: repo_path,
    strategy: {:branch, "agent/review"},
    sandbox: Sandboxes.docker()
  )

{:ok, _} =
  Sandbox.run(sandbox,
    agent: Agents.claude("claude-opus-4-8", approval_mode: :auto_approve),
    prompt_file: Path.join(__DIR__, "prompts/implement.md"),
    max_iterations: 5
  )

final =
  Enum.reduce_while(1..3, :never_tested, fn attempt, _acc ->
    {:ok, tests} = Sandbox.exec(sandbox, "mix test")

    if tests.exit_code == 0 do
      IO.puts("green")
      {:halt, :green}
    else
      {:ok, _} =
        Sandbox.run(sandbox,
          agent: Agents.claude("claude-sonnet-4-6", approval_mode: :auto_approve),
          prompt: "Attempt #{attempt}. The last test run failed:\n#{tests.stdout}"
        )

      {:cont, :red}
    end
  end)

if final != :green, do: IO.puts("still red after retry budget")

{:ok, _} = Sandbox.close(sandbox)
