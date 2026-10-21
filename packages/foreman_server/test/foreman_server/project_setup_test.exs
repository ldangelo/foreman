defmodule ForemanServer.ProjectSetupTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandRouter, ProjectSecrets, ProjectSetup}

  @moduletag :tmp_dir
  @secret "setup-secret-value-31337"

  setup %{tmp_dir: tmp_dir} do
    store = Application.get_env(:foreman_server, :secret_store)

    Application.put_env(
      :foreman_server,
      :secret_store,
      Keyword.put(store, :dir, Path.join(tmp_dir, "secrets"))
    )

    on_exit(fn -> Application.put_env(:foreman_server, :secret_store, store) end)

    project_id = "project-#{Elixir.EventStore.UUID.uuid4()}"

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: project_id, path: tmp_dir, config: %{}},
        aggregate_id: "project:#{project_id}"
      })

    worktree = Path.join(tmp_dir, "wt")
    File.mkdir_p!(worktree)
    %{project_id: project_id, worktree: worktree, log_dir: Path.join(tmp_dir, "logs")}
  end

  defp set_script(id, script, extra \\ %{}) do
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.environment.set",
        payload: Map.merge(%{project_id: id, setup_script: script}, extra),
        aggregate_id: "project:#{id}"
      })
  end

  test "no script is a no-op", ctx do
    assert :ok = ProjectSetup.run(ctx.project_id, ctx.worktree, "run-1", log_dir: ctx.log_dir)
    refute File.exists?(ctx.log_dir)
  end

  test "the script runs in the worktree with project env, secrets and FOREMAN_* ids", ctx do
    {:ok, _} = ProjectSecrets.set(ctx.project_id, "DEPLOY_PASSPHRASE", @secret, "t")

    set_script(
      ctx.project_id,
      ~s(echo "$NPM_REGISTRY|$FOREMAN_RUN_ID|$FOREMAN_PROJECT_ID|$FOREMAN_WORKTREE_PATH" > marker; echo "pw=$DEPLOY_PASSPHRASE"),
      %{vars: %{"NPM_REGISTRY" => "https://r.example"}}
    )

    assert :ok = ProjectSetup.run(ctx.project_id, ctx.worktree, "run-9", log_dir: ctx.log_dir)

    assert File.read!(Path.join(ctx.worktree, "marker")) ==
             "https://r.example|run-9|#{ctx.project_id}|#{ctx.worktree}\n"

    log = File.read!(Path.join(ctx.log_dir, "setup.log"))
    assert log =~ "pw=[REDACTED]"
    refute log =~ @secret
  end

  test "non-zero exit is a typed failure with a redacted tail", ctx do
    {:ok, _} = ProjectSecrets.set(ctx.project_id, "DEPLOY_PASSPHRASE", @secret, "t")
    set_script(ctx.project_id, ~s(echo "leaking $DEPLOY_PASSPHRASE" >&2; exit 7))

    assert {:error, {:setup_script_failed, 7, tail}} =
             ProjectSetup.run(ctx.project_id, ctx.worktree, "run-1", log_dir: ctx.log_dir)

    assert tail =~ "leaking [REDACTED]"
    refute tail =~ @secret
    refute File.read!(Path.join(ctx.log_dir, "setup.log")) =~ @secret
  end

  test "a script that outlives the timeout fails typed", ctx do
    previous = Application.get_env(:foreman_server, :project_setup)
    Application.put_env(:foreman_server, :project_setup, timeout_ms: 800)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:foreman_server, :project_setup, previous),
        else: Application.delete_env(:foreman_server, :project_setup)
    end)

    set_script(ctx.project_id, "echo begun; sleep 60")

    assert {:error, {:setup_script_timeout, 800, tail}} =
             ProjectSetup.run(ctx.project_id, ctx.worktree, "run-1", log_dir: ctx.log_dir)

    assert tail =~ "begun"
  end
end
