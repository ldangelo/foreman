defmodule ForemanServer.Jobsite.WorktreeTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.{Error, Git, Worktree}

  defp tmp_repo! do
    path = Path.join(System.tmp_dir!(), "jobsite-wt-#{System.unique_integer([:positive])}")
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

  describe ":merge_to_head strategy" do
    test "merges the commit onto the host branch and deletes the temp branch on close" do
      repo = tmp_repo!()
      {:ok, host_branch} = Git.current_branch(repo)

      assert {:ok, wt} = Worktree.create(repo_path: repo, strategy: :merge_to_head)
      assert wt.target_branch == host_branch
      assert String.starts_with?(wt.branch, "jobsite/")

      File.write!(Path.join(wt.path, "agent_work.txt"), "work")
      assert {:ok, :committed} = Git.commit_all(wt.path, "agent work")

      assert {:ok, %{merged?: true, preserved_path: nil}} = Worktree.close(wt)

      {log, 0} = System.cmd("git", ["-C", repo, "log", "--oneline", host_branch])
      assert log =~ "agent work"
      refute Git.branch_exists?(repo, wt.branch)
      refute File.dir?(wt.path)
    end

    test "discard/1 never merges: the work is dropped, the host branch is untouched" do
      repo = tmp_repo!()
      {:ok, host_branch} = Git.current_branch(repo)
      {:ok, before_sha} = Git.head_sha(repo)

      assert {:ok, wt} = Worktree.create(repo_path: repo, strategy: :merge_to_head)
      File.write!(Path.join(wt.path, "unfinished.txt"), "work")
      assert {:ok, :committed} = Git.commit_all(wt.path, "unfinished")

      assert :ok = Worktree.discard(wt)

      assert {:ok, ^before_sha} = Git.head_sha(repo)
      assert {:ok, ^host_branch} = Git.current_branch(repo)
      refute Git.branch_exists?(repo, wt.branch)
      refute File.dir?(wt.path)
    end

    test "a conflicting merge preserves the worktree and leaves the host repo clean" do
      repo = tmp_repo!()

      assert {:ok, wt} = Worktree.create(repo_path: repo, strategy: :merge_to_head)

      # Conflicting edits: host branch changes README.md after the worktree was cut...
      File.write!(Path.join(repo, "README.md"), "host change\n")
      assert {:ok, :committed} = Git.commit_all(repo, "host change")

      # ...and the worktree branch changes the same line differently.
      File.write!(Path.join(wt.path, "README.md"), "agent change\n")
      assert {:ok, :committed} = Git.commit_all(wt.path, "agent change")

      assert {:error, %Error{code: :merge_conflict}} = Worktree.close(wt)
      assert File.dir?(wt.path)
      refute Git.dirty?(repo)
    end
  end

  describe "{:branch, name} strategy" do
    test "the branch survives close/1" do
      repo = tmp_repo!()

      assert {:ok, wt} = Worktree.create(repo_path: repo, strategy: {:branch, "agent/basic"})
      assert wt.branch == "agent/basic"

      assert {:ok, %{merged?: false, preserved_path: nil}} = Worktree.close(wt)
      assert Git.branch_exists?(repo, "agent/basic")
    end

    test "a dirty worktree is preserved on close/1" do
      repo = tmp_repo!()

      assert {:ok, wt} = Worktree.create(repo_path: repo, strategy: {:branch, "agent/dirty"})
      File.write!(Path.join(wt.path, "scratch.txt"), "uncommitted")

      assert {:ok, %{preserved_path: path}} = Worktree.close(wt)
      assert path == wt.path
      assert File.dir?(wt.path)
    end

    test "refuses the branch checked out in the repo's main worktree" do
      repo = tmp_repo!()
      assert {:ok, main} = Git.current_branch(repo)

      assert {:error, %Error{code: :worktree_create_failed, message: message}} =
               Worktree.create(repo_path: repo, strategy: {:branch, main})

      assert message =~ "main worktree"
    end

    test "reuses an already-registered worktree for the same branch" do
      repo = tmp_repo!()

      assert {:ok, wt1} = Worktree.create(repo_path: repo, strategy: {:branch, "agent/reuse"})
      assert {:ok, wt2} = Worktree.create(repo_path: repo, strategy: {:branch, "agent/reuse"})
      # Compare directory identity rather than the literal string: git may
      # report a worktree's registered path with symlinks resolved (macOS
      # `/var` -> `/private/var`) even though both refer to the same directory.
      assert File.stat!(wt1.path) == File.stat!(wt2.path)
    end
  end

  describe "exclude_paths" do
    test "excludes a tracked directory from the worktree via sparse-checkout" do
      repo = tmp_repo!()
      File.mkdir_p!(Path.join(repo, ".beads"))
      File.write!(Path.join(repo, ".beads/issues.jsonl"), "{}\n")
      {_output, 0} = System.cmd("git", ["-C", repo, "add", "-A"])
      {_output, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "add beads"])

      assert {:ok, wt} =
               Worktree.create(
                 repo_path: repo,
                 strategy: {:branch, "agent/exclude"},
                 exclude_paths: ["/.beads/"]
               )

      refute File.exists?(Path.join(wt.path, ".beads"))
      refute Git.dirty?(wt.path)
    end
  end

  describe ":head strategy" do
    test "works directly in the caller's checkout" do
      repo = tmp_repo!()
      {:ok, branch} = Git.current_branch(repo)

      assert {:ok, wt} = Worktree.create(repo_path: repo, strategy: :head)
      assert wt.path == repo
      assert wt.branch == branch
      assert {:ok, %{merged?: false, preserved_path: nil}} = Worktree.close(wt)
    end

    test "rejects copy_to_worktree with :head" do
      repo = tmp_repo!()

      assert {:error, %Error{code: :branch_strategy_unsupported}} =
               Worktree.create(repo_path: repo, strategy: :head, copy_to_worktree: ["some/file"])
    end
  end
end
