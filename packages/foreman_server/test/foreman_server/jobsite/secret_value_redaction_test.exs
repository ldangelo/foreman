defmodule ForemanServer.Jobsite.SecretValueRedactionTest do
  # A project secret whose NAME gives nothing away (`DEPLOY_TARGET`: no `token`, `password`,
  # `secret`, ... in it) is redacted by VALUE wherever it could reach a durable surface.
  # The existing redaction tests use secret-looking names (`DEPLOY_PASSPHRASE`, `API_TOKEN`),
  # which name-pattern redaction alone would also catch; here only value-based redaction can.
  #
  # The secret is stored through `PUT /api/projects/:id/secrets/:name`; a real jobsite
  # (host sandbox, CLI-shaped fake agent that prints the env var it received) is launched
  # with session capture on; the project's instructions also carry the value, as an operator
  # pasting it into them would. Nothing durable may contain the value afterwards.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @moduletag :tmp_dir

  alias ForemanServer.{CommandRouter, EventStore}
  alias ForemanServer.Jobsite
  alias ForemanServer.Jobsite.{Agents, Sandboxes}

  @endpoint ForemanServerWeb.Endpoint
  @token "secret-value-redaction-token"
  @secret "zq-eu-central-7731-alpha"
  @fake_agent Path.join(__DIR__, "support/fake_agent.sh")

  setup %{tmp_dir: tmp_dir} do
    review = Application.get_env(:foreman_server, :review, [])
    store = Application.get_env(:foreman_server, :secret_store)
    previous_token = Application.get_env(:foreman_server, :api_bearer_token)

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(review, capture: true, archive_root: Path.join(tmp_dir, "archive"))
    )

    Application.put_env(
      :foreman_server,
      :secret_store,
      Keyword.put(store, :dir, Path.join(tmp_dir, "secrets"))
    )

    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      Application.put_env(:foreman_server, :review, review)
      Application.put_env(:foreman_server, :secret_store, store)

      if previous_token == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous_token)
    end)

    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["-C", repo, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "t@example.com"])
    {_, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "-A"])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "init"])

    project_id = "value-redaction-#{Elixir.EventStore.UUID.uuid4()}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{
          project_id: project_id,
          path: repo,
          config: %{instructions: "Ship to target #{@secret} and nowhere else."}
        },
        aggregate_id: "project:#{project_id}"
      })

    assert %{"name" => "DEPLOY_TARGET", "version" => 1} =
             api(:put, "/api/projects/#{project_id}/secrets/DEPLOY_TARGET", %{"value" => @secret})
             |> json_response(200)

    {id, result} = launch(repo, project_id)

    {:ok,
     repo: repo,
     project_id: project_id,
     jobsite_id: id,
     result: result,
     archive: Path.join([tmp_dir, "archive", "jobsite", id])}
  end

  defp api(method, path, body \\ nil) do
    conn = build_conn() |> put_req_header("authorization", "Bearer #{@token}")

    case body do
      nil ->
        dispatch(conn, @endpoint, method, path)

      body ->
        conn
        |> put_req_header("content-type", "application/json")
        |> dispatch(@endpoint, method, path, Jason.encode!(body))
    end
  end

  defp launch(repo, project_id) do
    {:ok, %{jobsite_id: id} = result} =
      Jobsite.run(
        repo_path: repo,
        strategy: :merge_to_head,
        sandbox: Sandboxes.host(),
        agent:
          Agents.pi("x", binary: @fake_agent, env: %{"FAKE_AGENT_ECHO_ENV" => "DEPLOY_TARGET"}),
        prompt: "go",
        project_id: project_id
      )

    {id, result}
  end

  # Every file of the session archive, by name.
  defp archive_files(archive) do
    archive
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, archive), File.read!(&1)})
  end

  test "the agent received the value, yet no result, event, projection or archive file holds it",
       ctx do
    # The agent really got the secret: the marker stands where the echoed value was.
    assert [%{text: "env:DEPLOY_TARGET=[REDACTED]"}] = ctx.result.iterations
    refute inspect(ctx.result) =~ @secret

    {:ok, events} = EventStore.read_stream_forward("jobsite:" <> ctx.jobsite_id, 0, 99_999)
    assert events != []
    refute inspect(events) =~ @secret
    refute inspect(Jobsite.get(ctx.jobsite_id)) =~ @secret

    files = archive_files(ctx.archive)
    assert Map.has_key?(files, "transcript.jsonl")
    assert files["transcript.jsonl"] =~ "env:DEPLOY_TARGET=[REDACTED]"

    for {name, text} <- files, text =~ @secret do
      flunk("session archive file #{name} contains the secret value")
    end
  end

  test "the standing project context carries the value nowhere: not in the launch, the archive or the API",
       ctx do
    context = File.read!(Path.join(ctx.archive, "project-context.md"))
    assert context =~ "Ship to target [REDACTED] and nowhere else."
    refute context =~ @secret

    manifest = ctx.archive |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    assert manifest["project_context"]["redactions"] == 1

    body = api(:get, "/api/projects/#{ctx.project_id}/context") |> response(200)
    assert body =~ "Ship to target [REDACTED] and nowhere else."
    refute body =~ @secret
  end
end
