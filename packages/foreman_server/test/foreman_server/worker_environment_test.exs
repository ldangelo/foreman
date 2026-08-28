defmodule ForemanServer.WorkerEnvironmentTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandRouter, WorkerEnvironment}

  test "build_env_map/1 returns the complete env map for a registered project" do
    project_id = unique_project_id()
    env_map = %{"ALPHA" => "one", "BETA" => "two", "FEATURE_FLAG" => "enabled"}

    register_project(project_id, env_map)

    assert WorkerEnvironment.build_env_map(project_id) == env_map
  end

  test "build_env_map/1 scopes env to the requested project" do
    first_project_id = unique_project_id()
    second_project_id = unique_project_id()

    register_project(first_project_id, %{"FIRST_ONLY" => "1"})
    register_project(second_project_id, %{"SECOND_ONLY" => "2"})

    assert WorkerEnvironment.build_env_map(first_project_id) == %{"FIRST_ONLY" => "1"}
    assert WorkerEnvironment.build_env_map(second_project_id) == %{"SECOND_ONLY" => "2"}
  end

  test "running worker keeps its launch-time env snapshot after config changes" do
    project_id = unique_project_id()

    register_project(project_id, %{"TOKEN" => "old"})

    launched_env = WorkerEnvironment.build_env_map(project_id)

    update_project_env(project_id, %{"TOKEN" => "new", "EXTRA" => "next-launch"})

    assert launched_env == %{"TOKEN" => "old"}
  end

  test "refresh_on_relaunch/2 rebuilds env from the latest project config" do
    project_id = unique_project_id()

    register_project(project_id, %{"TOKEN" => "old"})

    launched_env = WorkerEnvironment.build_env_map(project_id)
    update_project_env(project_id, %{"TOKEN" => "new", "EXTRA" => "next-launch"})

    assert WorkerEnvironment.refresh_on_relaunch(project_id, launched_env) == %{
             "TOKEN" => "new",
             "EXTRA" => "next-launch"
           }
  end

  test "extract_secrets/1 returns values for known secret key names" do
    env = %{
      "OPENAI_API_KEY" => "sk-secret-openai",
      "GITHUB_TOKEN" => "ghp_secret123",
      "PASSWORD" => "pass456",
      "AWS_SECRET_ACCESS_KEY" => "aws-secret-key",
      "ENCRYPTION_KEY" => "enc-key-xyz",
      "SIGNING_KEY" => "sign-key-abc",
      "MASTER_KEY" => "master-key-789",
      "USERNAME" => "alice",
      "HOME" => "/Users/alice",
      "DATABASE_URL" => "postgres://..."
    }

    secrets = WorkerEnvironment.extract_secrets(env)

    assert "sk-secret-openai" in secrets
    assert "ghp_secret123" in secrets
    assert "pass456" in secrets
    assert "aws-secret-key" in secrets
    assert "enc-key-xyz" in secrets
    assert "sign-key-abc" in secrets
    assert "master-key-789" in secrets
    refute "alice" in secrets
    refute "/Users/alice" in secrets
    refute "postgres://..." in secrets
  end

  test "extract_secrets/1 returns empty list for env with no secret keys" do
    env = %{"HOME" => "/tmp", "PATH" => "/bin", "USER" => "bob"}
    assert WorkerEnvironment.extract_secrets(env) == []
  end

  defp register_project(project_id, env_map) do
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{
          project_id: project_id,
          path: "/tmp/#{project_id}",
          config: %{env: env_map}
        },
        aggregate_id: "project:#{project_id}"
      })
  end

  defp update_project_env(project_id, env_map) do
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.update",
        payload: %{
          project_id: project_id,
          config: %{env: env_map}
        },
        aggregate_id: "project:#{project_id}"
      })
  end

  defp unique_project_id do
    "project-#{Elixir.EventStore.UUID.uuid4()}"
  end
end
