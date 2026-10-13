defmodule ForemanServer.Jobsite.Sandboxes.DockerGitMountTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.Sandboxes.Docker

  defp git!(dir, args), do: {_, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)

  setup do
    root = Path.join(System.tmp_dir!(), "docker-gitmount-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "a"), "a")
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, repo: repo}
  end

  test "a linked worktree gets the repo git dir mounted at the same host path", %{
    root: root,
    repo: repo
  } do
    wt = Path.join(root, "wt")
    git!(repo, ["worktree", "add", "-q", "-b", "agent/x", wt])

    git_dir = Path.join(Path.expand(repo) |> realpath(), ".git")
    assert Docker.git_mount_args(wt) == ["-v", "#{git_dir}:#{git_dir}"]
  end

  test "a checkout whose .git is a directory needs no extra mount", %{repo: repo} do
    assert Docker.git_mount_args(repo) == []
  end

  defp realpath(path) do
    {out, 0} = System.cmd("realpath", [path])
    String.trim(out)
  end
end
