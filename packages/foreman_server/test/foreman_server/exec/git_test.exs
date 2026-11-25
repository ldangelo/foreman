defmodule ForemanServer.Exec.GitTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Exec.{Error, Git}

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
      assert {:error, %ForemanServer.Exec.Error{}} =
               Git.commit_all("/nonexistent/path/#{System.unique_integer([:positive])}", "msg")
    end
  end

  describe "commit_all/3 .beads hygiene" do
    @runtime_files ~w(beads.db beads.db-wal beads.db-shm beads.db-wal-cert beads.db.bak
                      .br-wal-index-1 .write.lock bd.sock last-touched)

    defp beads_repo!(opts \\ []) do
      path = tmp_repo!()
      beads = Path.join(path, ".beads")
      File.mkdir_p!(beads)
      File.cp!("test/fixtures/beads_gitignore", Path.join(beads, ".gitignore"))
      File.write!(Path.join(beads, "config.yaml"), "a: 1\n")
      File.write!(Path.join(beads, "issues.jsonl"), "")
      {_, 0} = System.cmd("git", ["-C", path, "add", "-A"])
      {_, 0} = System.cmd("git", ["-C", path, "commit", "-q", "-m", "beads"])
      if opts[:no_gitignore], do: File.rm!(Path.join(beads, ".gitignore"))
      for f <- @runtime_files, do: File.write!(Path.join(beads, f), "runtime")
      path
    end

    defp committed_files(path) do
      {out, 0} = System.cmd("git", ["-C", path, "show", "--name-status", "--format=", "HEAD"])
      out
    end

    test "never stages runtime files even when the agent deleted .beads/.gitignore" do
      path = beads_repo!(no_gitignore: true)
      File.write!(Path.join(path, "work.txt"), "x")

      assert {:ok, :committed} = Git.commit_all(path, "msg")

      out = committed_files(path)
      assert out =~ "work.txt"
      refute out =~ ".beads/beads.db"
      refute out =~ ".br-wal-index"
      refute out =~ "last-touched"
      # the deletion of .beads/.gitignore is not committed; the file is restored
      refute out =~ ".beads/.gitignore"
      assert File.exists?(Path.join(path, ".beads/.gitignore"))
    end

    test "never stages a modification of .beads/.gitignore" do
      path = beads_repo!()
      File.write!(Path.join(path, ".beads/.gitignore"), "")
      File.write!(Path.join(path, "work.txt"), "x")

      assert {:ok, :committed} = Git.commit_all(path, "msg")
      refute committed_files(path) =~ ".beads/.gitignore"
    end

    test "runtime files alone are nothing to commit, not a failed commit" do
      path = beads_repo!(no_gitignore: true)
      {:ok, before} = Git.head_sha(path)

      assert {:ok, :nothing_to_commit} = Git.commit_all(path, "msg")
      assert {:ok, ^before} = Git.head_sha(path)
    end

    test "a worktree whose sparse-checkout hides .beads commits instead of failing the restore" do
      path = beads_repo!()
      {_, 0} = System.cmd("git", ["-C", path, "sparse-checkout", "init", "--no-cone"])

      {_, 0} =
        System.cmd("git", [
          "-C",
          path,
          "sparse-checkout",
          "set",
          "/*",
          "!/.beads/",
          "!/.beads/**"
        ])

      # Hidden by sparse-checkout, still tracked: absent on disk by design.
      refute File.exists?(Path.join(path, ".beads/.gitignore"))
      File.write!(Path.join(path, "work.txt"), "x")

      assert {:ok, :committed} = Git.commit_all(path, "msg")

      out = committed_files(path)
      assert out =~ "work.txt"
      refute out =~ ".beads"
    end

    test "the exported ledger (issues.jsonl) and config.yaml are still committed" do
      path = beads_repo!()
      File.write!(Path.join(path, ".beads/issues.jsonl"), "{\"id\":\"x\"}\n")

      assert {:ok, :committed} = Git.commit_all(path, "msg")
      out = committed_files(path)
      assert out =~ ".beads/issues.jsonl"
      refute out =~ "beads.db"
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

  describe "branch_exists?/2 and worktree_add_args/4" do
    test "a nil branch never exists and adds a detached worktree at the base" do
      path = tmp_repo!()
      {:ok, base} = Git.head_sha(path)

      refute Git.branch_exists?(path, nil)

      assert Git.worktree_add_args(path, "/wt", nil, base) ==
               ["-C", path, "worktree", "add", "--detach", "/wt", base]
    end

    test "a nil branch with a branch-name base still adds a detached worktree" do
      path = tmp_repo!()
      {_output, 0} = System.cmd("git", ["-C", path, "branch", "other"])
      wt = path <> "-wt"
      on_exit(fn -> File.rm_rf(wt) end)

      assert :ok = Git.worktree_add(path, wt, nil, "other")

      # Without `--detach`, git attaches the worktree to `other`.
      assert {_output, code} =
               System.cmd("git", ["-C", wt, "symbolic-ref", "--quiet", "HEAD"],
                 stderr_to_stdout: true
               )

      assert code != 0
    end

    test "attaches an existing branch and creates a missing one from the base" do
      path = tmp_repo!()
      {:ok, base} = Git.head_sha(path)
      {:ok, current} = Git.current_branch(path)

      assert Git.branch_exists?(path, current)

      assert Git.worktree_add_args(path, "/wt", current, base) ==
               ["-C", path, "worktree", "add", "/wt", current]

      refute Git.branch_exists?(path, "feat/new")

      assert Git.worktree_add_args(path, "/wt", "feat/new", base) ==
               ["-C", path, "worktree", "add", "-b", "feat/new", "/wt", base]
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

  describe "fetch_remote_tip/3" do
    setup do
      origin =
        Path.join(System.tmp_dir!(), "jobsite-git-origin-#{System.unique_integer([:positive])}")

      File.mkdir_p!(origin)
      {_output, 0} = System.cmd("git", ["-C", origin, "init", "-q", "--bare"])

      repo =
        Path.join(System.tmp_dir!(), "jobsite-git-clone-#{System.unique_integer([:positive])}")

      {_output, 0} = System.cmd("git", ["clone", "-q", origin, repo])
      {_output, 0} = System.cmd("git", ["-C", repo, "config", "user.email", "test@example.com"])
      {_output, 0} = System.cmd("git", ["-C", repo, "config", "user.name", "Test"])
      {_output, 0} = System.cmd("git", ["-C", repo, "checkout", "-q", "-B", "main"])

      File.write!(Path.join(repo, "README.md"), "hello\n")
      {_output, 0} = System.cmd("git", ["-C", repo, "add", "-A"])
      {_output, 0} = System.cmd("git", ["-C", repo, "commit", "-q", "-m", "init"])

      {_output, 0} =
        System.cmd("git", ["-C", repo, "push", "-q", "origin", "HEAD:refs/heads/main"])

      on_exit(fn ->
        File.rm_rf(origin)
        File.rm_rf(repo)
      end)

      %{repo: repo, origin: origin}
    end

    test "answers the remote's tip and leaves the checkout's HEAD alone", %{repo: repo} do
      {:ok, stale} = Git.head_sha(repo)

      {_output, 0} =
        System.cmd("git", ["-C", repo, "commit", "-q", "--allow-empty", "-m", "ahead"])

      {_output, 0} =
        System.cmd("git", ["-C", repo, "push", "-q", "origin", "HEAD:refs/heads/main"])

      {:ok, ahead} = Git.head_sha(repo)
      {_output, 0} = System.cmd("git", ["-C", repo, "reset", "-q", "--hard", "HEAD~1"])

      # The push above already moved the remote-tracking ref forward; point it
      # back at the stale commit so the fetch has to move it forward again.
      {_output, 0} =
        System.cmd("git", ["-C", repo, "update-ref", "refs/remotes/origin/main", stale])

      assert Git.ref_sha(repo, "refs/remotes/origin/main") == {:ok, stale}

      assert Git.fetch_remote_tip(repo, "origin", "main") == {:ok, ahead}
      assert Git.head_sha(repo) == {:ok, stale}
      assert Git.ref_sha(repo, "refs/remotes/origin/main") == {:ok, ahead}
    end

    test "a remote that does not carry the branch is reported as missing", %{repo: repo} do
      assert Git.fetch_remote_tip(repo, "origin", "feat/absent") ==
               {:error, {:remote_branch_missing, "origin", "feat/absent"}}
    end

    test "a checkout without the remote reports no remote", %{repo: repo} do
      assert Git.fetch_remote_tip(repo, "upstream", "main") == {:error, :no_remote}
    end

    test "an unreadable remote fails with a git error", %{repo: repo} do
      gone =
        Path.join(System.tmp_dir!(), "jobsite-git-gone-#{System.unique_integer([:positive])}")

      {_output, 0} = System.cmd("git", ["-C", repo, "remote", "set-url", "origin", gone])

      assert {:error, {:remote_unreadable, "origin", "main"}} =
               Git.fetch_remote_tip(repo, "origin", "main")
    end

    test "a fetch that fails against a readable remote is reported as a fetch failure", %{
      repo: repo,
      origin: origin
    } do
      peer =
        Path.join(System.tmp_dir!(), "jobsite-git-peer-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(peer) end)

      {_output, 0} = System.cmd("git", ["clone", "-q", "--branch", "main", origin, peer])
      {_output, 0} = System.cmd("git", ["-C", peer, "config", "user.email", "test@example.com"])
      {_output, 0} = System.cmd("git", ["-C", peer, "config", "user.name", "Test"])
      File.write!(Path.join(peer, "ahead.txt"), "ahead\n")
      {_output, 0} = System.cmd("git", ["-C", peer, "add", "-A"])
      {_output, 0} = System.cmd("git", ["-C", peer, "commit", "-q", "-m", "ahead"])
      {_output, 0} =
        System.cmd("git", ["-C", peer, "push", "-q", "origin", "HEAD:refs/heads/main"])

      # The remote still advertises the branch, but it cannot serve the objects
      # the branch needs: the branch is readable, the fetch is not.
      {tree, 0} = System.cmd("git", ["-C", peer, "rev-parse", "HEAD^{tree}"])
      tree = String.trim(tree)
      object = Path.join(origin, "objects/#{String.slice(tree, 0, 2)}/#{String.slice(tree, 2..-1//1)}")
      assert File.exists?(object)
      File.rm!(object)

      assert {:error, {:fetch_failed, "origin", "main", %Error{code: :git_failed}}} =
               Git.fetch_remote_tip(repo, "origin", "main")
    end
  end
end
