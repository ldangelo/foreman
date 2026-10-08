defmodule ForemanServer.Jobsite.Sandboxes.DockerTest do
  # Real `docker` daemon required — excluded by default (test_helper.exs),
  # run with `mix test --include docker`.
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite.Sandboxes.Docker
  alias ForemanServer.Jobsite.Worktree

  @moduletag :docker
  @image "alpine:latest"

  setup_all do
    case System.cmd("docker", ["image", "inspect", @image], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        {_, 0} = System.cmd("docker", ["pull", @image], stderr_to_stdout: true)
        :ok
    end
  end

  defp tmp_repo! do
    path = Path.join(System.tmp_dir!(), "docker-sandbox-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    {_output, 0} = System.cmd("git", ["-C", path, "init", "-q"])
    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.email", "test@example.com"])
    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "hello\n")
    {_output, 0} = System.cmd("git", ["-C", path, "add", "-A"])
    {_output, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "exec writes a file visible in the host worktree (bind mount), owned by the host uid" do
    repo = tmp_repo!()
    assert {:ok, worktree} = Worktree.create(repo_path: repo, strategy: :head)
    on_exit(fn -> Worktree.close(worktree) end)

    assert {:ok, state, sandbox_path, container} = Docker.create(%{image: @image}, worktree)
    on_exit(fn -> Docker.close(state) end)
    assert sandbox_path == "/workspace"
    assert is_binary(container) and container != ""

    assert {:ok, result} = Docker.exec(state, "echo hello > container-written.txt", [])
    assert result.exit_code == 0

    host_path = Path.join(worktree.path, "container-written.txt")
    assert File.read!(host_path) == "hello\n"

    host_uid = String.to_integer(state.uid)
    %File.Stat{uid: file_uid} = File.stat!(host_path)
    assert file_uid == host_uid
  end

  test "agent_cli_path produces an executable shim whose docker exec reaches the right container" do
    repo = tmp_repo!()
    assert {:ok, worktree} = Worktree.create(repo_path: repo, strategy: :head)
    on_exit(fn -> Worktree.close(worktree) end)

    assert {:ok, state, _sandbox_path, _container} = Docker.create(%{image: @image}, worktree)
    on_exit(fn -> Docker.close(state) end)

    assert {:ok, shim_path} = Docker.agent_cli_path(state, "env", %{"JOBSITE_TEST_VAR" => "shim-value"})
    assert File.exists?(shim_path)
    assert Bitwise.band(File.stat!(shim_path).mode, 0o111) != 0

    {output, 0} = System.cmd(shim_path, [])
    assert output =~ "JOBSITE_TEST_VAR=shim-value"
  end
end
