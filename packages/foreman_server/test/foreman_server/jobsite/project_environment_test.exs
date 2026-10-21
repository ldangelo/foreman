defmodule ForemanServer.Jobsite.ProjectEnvironmentTest do
  # A real jobsite run (host sandbox, fake Pi-shaped agent that echoes one env
  # var) for a project with an environment record and a stored secret. What
  # counts is what the agent process received and what reached events/archives.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.{CommandRouter, EventStore, ProjectSecrets}
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Sandboxes}

  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")
  @secret "jb-secret-value-90210"

  setup %{tmp_dir: tmp_dir} do
    review = Application.get_env(:foreman_server, :review, [])

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(review, capture: true, archive_root: Path.join(tmp_dir, "archive"))
    )

    store = Application.get_env(:foreman_server, :secret_store)

    Application.put_env(
      :foreman_server,
      :secret_store,
      Keyword.put(store, :dir, Path.join(tmp_dir, "secrets"))
    )

    on_exit(fn ->
      Application.put_env(:foreman_server, :review, review)
      Application.put_env(:foreman_server, :secret_store, store)
    end)

    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["-C", repo, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "init"])

    project_id = "project-#{Elixir.EventStore.UUID.uuid4()}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: project_id, path: repo, config: %{}},
        aggregate_id: "project:#{project_id}"
      })

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.environment.set",
        payload: %{project_id: project_id, vars: %{"NPM_REGISTRY" => "https://reg.example"}},
        aggregate_id: "project:#{project_id}"
      })

    {:ok, _} = ProjectSecrets.set(project_id, "DEPLOY_PASSPHRASE", @secret, "test")

    %{repo: repo, project_id: project_id, archive_root: Path.join(tmp_dir, "archive")}
  end

  defp run(ctx, echo, agent_env \\ %{}) do
    agent =
      Agents.pi("x",
        binary: @fake_agent,
        env: Map.merge(%{"FAKE_AGENT_ECHO_ENV" => echo}, agent_env)
      )

    {:ok, %{jobsite_id: id} = result} =
      Jobsite.run(
        repo_path: ctx.repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent: agent,
        prompt: "go",
        project_id: ctx.project_id
      )

    {id, result}
  end

  defp transcript(root, id) do
    root |> Path.join("jobsite/#{id}/transcript.jsonl") |> File.read!()
  end

  test "project vars reach the agent", ctx do
    {id, _} = run(ctx, "NPM_REGISTRY")
    assert transcript(ctx.archive_root, id) =~ "env:NPM_REGISTRY=https://reg.example"
  end

  test "the spec's own agent env overrides a project var", ctx do
    {id, _} = run(ctx, "NPM_REGISTRY", %{"NPM_REGISTRY" => "https://override.example"})
    text = transcript(ctx.archive_root, id)
    assert text =~ "https://override.example"
    refute text =~ "reg.example"
  end

  test "secret values reach the agent but never events, results or the archive", ctx do
    {id, result} = run(ctx, "DEPLOY_PASSPHRASE")

    # The agent really received the value: the redaction marker is where the
    # echoed value was.
    assert transcript(ctx.archive_root, id) =~ "env:DEPLOY_PASSPHRASE=[REDACTED]"
    refute transcript(ctx.archive_root, id) =~ @secret
    refute inspect(result) =~ @secret

    {:ok, events} = EventStore.read_stream_forward("jobsite:" <> id, 0, 99_999)
    refute inspect(events) =~ @secret

    manifest = File.read!(Path.join([ctx.archive_root, "jobsite", id, "manifest.json"]))
    refute manifest =~ @secret
  end

  defp set_script(ctx, script) do
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.environment.set",
        payload: %{project_id: ctx.project_id, setup_script: script},
        aggregate_id: "project:#{ctx.project_id}"
      })
  end

  test "the project setup script runs on the fresh worktree before the agent", ctx do
    set_script(ctx, ~s(echo "$NPM_REGISTRY $FOREMAN_PROJECT_ID" > setup-marker.txt))
    {id, _} = run(ctx, "NPM_REGISTRY")

    diff = File.read!(Path.join([ctx.archive_root, "jobsite", id, "diff.patch"]))
    assert diff =~ "setup-marker.txt"
    assert diff =~ "https://reg.example #{ctx.project_id}"
  end

  test "a failing setup script fails the jobsite before the agent starts", ctx do
    set_script(ctx, ~s(echo "boom $DEPLOY_PASSPHRASE"; exit 5))

    assert {:error, %ForemanServer.Jobsite.Error{code: :hook_failed, details: details}} =
             Jobsite.run(
               repo_path: ctx.repo,
               strategy: :merge_to_head,
               sandbox: Sandboxes.host(),
               agent: Agents.pi("x", binary: @fake_agent),
               prompt: "go",
               project_id: ctx.project_id
             )

    assert details.exit_code == 5
    assert details.output =~ "boom [REDACTED]"
    refute inspect(details) =~ @secret
  end
end
