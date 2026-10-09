defmodule ForemanServer.Jobsite.GitTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.{Error, Git}

  defp tmp_repo! do
    path = Path.join(System.tmp_dir!(), "jobsite-git-#{System.unique_integer([:positive])}")
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

  describe "commit_all/3" do
    test "succeeds on a checkout with user.email/user.name unset" do
      path = tmp_repo!()
      # Unset the repo-local identity the helper configured.
      System.cmd("git", ["-C", path, "config", "--unset", "user.email"])
      System.cmd("git", ["-C", path, "config", "--unset", "user.name"])

      File.write!(Path.join(path, "a.txt"), "x")

      assert {:ok, :committed} = Git.commit_all(path, "msg")
    end

    test "an untracked-only file counts as work" do
      path = tmp_repo!()
      File.write!(Path.join(path, "untracked.txt"), "x")

      assert {:ok, :committed} = Git.commit_all(path, "msg")
      assert Git.dirty?(path) == false
    end

    test "a clean tree returns {:ok, :nothing_to_commit} and creates no commit" do
      path = tmp_repo!()
      {:ok, before} = Git.head_sha(path)

      assert {:ok, :nothing_to_commit} = Git.commit_all(path, "msg")
      assert {:ok, ^before} = Git.head_sha(path)
    end

    test "an unreadable directory returns {:error, %Error{}}, never a skip" do
      assert {:error, %ForemanServer.Jobsite.Error{}} =
               Git.commit_all("/nonexistent/path/#{System.unique_integer([:positive])}", "msg")
    end
  end

  describe "dirty?/1" do
    test "a status that cannot run is dirty, never clean" do
      path = tmp_repo!()
      File.write!(Path.join([path, ".git", "index"]), "not an index")

      assert Git.dirty?(path)
    end

    test "a directory that no longer exists has nothing to lose" do
      refute Git.dirty?(
               Path.join(System.tmp_dir!(), "gone-#{System.unique_integer([:positive])}")
             )
    end
  end

  describe "merge/2" do
    test "a merge that fails without leaving a merge in progress is :merge_failed, not a conflict" do
      path = tmp_repo!()

      assert {:error, {:merge_failed, _output}} = Git.merge(path, "no-such-branch")

      assert %Error{code: :merge_failed} =
               Git.merge_error(path, "no-such-branch", {:merge_failed, "x"})
    end
  end

  describe "current_branch/1" do
    test "returns the checked-out branch name" do
      path = tmp_repo!()
      assert {:ok, branch} = Git.current_branch(path)
      assert is_binary(branch) and branch != ""
    end
  end

  describe "commits_between/3" do
    test "lists commits made after base_sha" do
      path = tmp_repo!()
      {:ok, base} = Git.head_sha(path)

      File.write!(Path.join(path, "b.txt"), "y")
      {:ok, :committed} = Git.commit_all(path, "second commit")

      assert {:ok, [%{subject: "second commit"}]} = Git.commits_between(path, base, "HEAD")
    end
  end
end
