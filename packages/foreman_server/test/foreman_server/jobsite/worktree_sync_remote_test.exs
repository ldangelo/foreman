defmodule ForemanServer.Jobsite.WorktreeSyncRemoteTest do
  @moduledoc """
  `sync_remote: "origin"` (E9-S3): a fix jobsite attaches to a PR branch at its
  CURRENT remote tip - fetch, then fast-forward ONLY. History is never rewritten and
  local work is never discarded; a branch that cannot be fast-forwarded is a typed
  error. Real temporary git repositories, no stubs.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.{Error, Git, Worktree}
  alias ForemanServer.TestSupport.PrFixSupport, as: Fix

  @branch "feat/pr-head"

  setup do
    root = Path.join(System.tmp_dir!(), "wtsync-#{Base.encode16(:crypto.strong_rand_bytes(6))}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    origin = Path.join(root, "origin.git")
    Fix.git!(root, ["init", "-q", "--bare", "-b", "main", origin])

    # the agent's checkout, and a second clone playing the human who pushes to the PR
    repo = clone!(origin, Path.join(root, "repo"))
    peer = clone!(origin, Path.join(root, "peer"))

    Fix.commit_file!(peer, "base.txt", "base\n")
    Fix.git!(peer, ["push", "-q", "origin", "main"])
    Fix.git!(repo, ["pull", "-q", "origin", "main"])

    %{root: root, origin: origin, repo: repo, peer: peer}
  end

  defp clone!(origin, path) do
    Fix.git!(Path.dirname(path), ["clone", "-q", origin, path])
    Fix.git!(path, ["symbolic-ref", "HEAD", "refs/heads/main"])
    Fix.git!(path, ["config", "user.email", "test@example.com"])
    Fix.git!(path, ["config", "user.name", "Test"])
    Fix.git!(path, ["config", "commit.gpgsign", "false"])
    path
  end

  # `peer` pushes `count` commits to the PR branch (created from main when absent).
  defp peer_pushes!(peer, count) do
    if Fix.git!(peer, ["branch", "--list", @branch]) == "" do
      Fix.git!(peer, ["checkout", "-q", "-b", @branch])
    end

    shas =
      for n <- 1..count,
          do: Fix.commit_file!(peer, "pr-#{System.unique_integer([:positive])}-#{n}.txt", "x\n")

    Fix.git!(peer, ["push", "-q", "origin", @branch])
    List.last(shas)
  end

  defp attach(repo, extra \\ []) do
    Worktree.create(
      [repo_path: repo, strategy: {:branch, @branch}, sync_remote: "origin"] ++ extra
    )
  end

  defp local_sha(repo), do: Fix.git!(repo, ["rev-parse", "refs/heads/#{@branch}"])
  defp remote_sha(origin), do: Fix.git!(origin, ["rev-parse", "refs/heads/#{@branch}"])

  describe "Git.fetch_branch/4" do
    test "fetches exactly the named branch into refs/remotes and follows a force-push",
         %{repo: repo, peer: peer, origin: origin} do
      first = peer_pushes!(peer, 1)
      assert :ok = Git.fetch_branch(repo, "origin", @branch)
      assert {:ok, ^first} = Git.ref_sha(repo, "refs/remotes/origin/#{@branch}")

      # the human rewrites the PR branch; the tracking ref must follow (it is a mirror,
      # not a merge)
      Fix.git!(peer, ["reset", "-q", "--hard", "HEAD~1"])
      rewritten = Fix.commit_file!(peer, "rewritten.txt", "y\n")
      Fix.git!(peer, ["push", "-q", "--force", "origin", @branch])
      assert remote_sha(origin) == rewritten

      assert :ok = Git.fetch_branch(repo, "origin", @branch)
      assert {:ok, ^rewritten} = Git.ref_sha(repo, "refs/remotes/origin/#{@branch}")
      # nothing local was created or touched by a fetch
      assert Fix.git!(repo, ["branch", "--list", @branch]) == ""
    end

    test "a missing remote branch and option-looking names are typed errors, never run",
         %{repo: repo} do
      assert {:error, %Error{code: :git_failed, details: %{branch: @branch}}} =
               Git.fetch_branch(repo, "origin", @branch)

      assert {:error, %Error{code: :git_failed, details: %{role: :branch}}} =
               Git.fetch_branch(repo, "origin", "--upload-pack=touch /tmp/pwned")

      assert {:error, %Error{code: :git_failed, details: %{role: :remote}}} =
               Git.fetch_branch(repo, "--evil", @branch)
    end
  end

  describe "Worktree.create/1 with sync_remote" do
    test "a PR branch that exists only on origin is created at its tip",
         %{repo: repo, peer: peer} do
      tip = peer_pushes!(peer, 2)
      assert Fix.git!(repo, ["branch", "--list", @branch]) == ""

      assert {:ok, wt} = attach(repo)

      assert wt.base_sha == tip
      assert local_sha(repo) == tip
      assert Fix.git!(wt.path, ["rev-parse", "HEAD"]) == tip
      assert wt.branch == @branch
    end

    test "a local branch that is behind is fast-forwarded and its history is preserved",
         %{repo: repo, peer: peer} do
      first = peer_pushes!(peer, 1)
      Fix.git!(repo, ["fetch", "-q", "origin", @branch])
      Fix.git!(repo, ["branch", @branch, first])

      tip = peer_pushes!(peer, 2)

      assert {:ok, wt} = attach(repo)

      assert wt.base_sha == tip
      assert local_sha(repo) == tip
      assert Git.ancestor?(repo, first, tip)
      assert Fix.git!(wt.path, ["rev-parse", "HEAD"]) == tip
    end

    test "a behind branch already checked out in a worktree is moved with merge --ff-only there",
         %{repo: repo, peer: peer, root: root} do
      first = peer_pushes!(peer, 1)
      Fix.git!(repo, ["fetch", "-q", "origin", @branch])
      existing = Path.join(root, "existing-wt")
      Fix.git!(repo, ["worktree", "add", "-q", "-b", @branch, existing, first])
      tip = peer_pushes!(peer, 1)

      assert {:ok, wt} = attach(repo)

      assert File.dir?(existing)
      assert Fix.git!(existing, ["rev-parse", "HEAD"]) == tip
      assert wt.base_sha == tip
      assert local_sha(repo) == tip
    end

    test "a behind branch checked out in the MAIN worktree is refused before anything moves",
         %{repo: repo, peer: peer} do
      first = peer_pushes!(peer, 1)
      Fix.git!(repo, ["fetch", "-q", "origin", @branch])
      Fix.git!(repo, ["checkout", "-q", "-b", @branch, first])
      peer_pushes!(peer, 1)

      assert {:error, %Error{code: :worktree_create_failed, details: %{branch: @branch}}} =
               attach(repo)

      assert local_sha(repo) == first
      assert Fix.git!(repo, ["rev-parse", "HEAD"]) == first
    end

    test "a behind branch in a linked worktree with uncommitted changes is not fast-forwarded",
         %{repo: repo, peer: peer, root: root} do
      first = peer_pushes!(peer, 1)
      Fix.git!(repo, ["fetch", "-q", "origin", @branch])
      existing = Path.join(root, "dirty-wt")
      Fix.git!(repo, ["worktree", "add", "-q", "-b", @branch, existing, first])
      File.write!(Path.join(existing, "wip.txt"), "unsaved\n")
      peer_pushes!(peer, 1)

      assert {:error, %Error{code: :worktree_create_failed, details: %{branch: @branch}}} =
               attach(repo)

      assert local_sha(repo) == first
      assert File.read!(Path.join(existing, "wip.txt")) == "unsaved\n"
    end

    test "unpushed local commits are never discarded: the attach is refused", %{
      repo: repo,
      peer: peer
    } do
      first = peer_pushes!(peer, 1)
      Fix.git!(repo, ["fetch", "-q", "origin", @branch])
      Fix.git!(repo, ["branch", @branch, first])
      Fix.git!(repo, ["checkout", "-q", @branch])
      unpushed = Fix.commit_file!(repo, "local-only.txt", "mine\n")
      Fix.git!(repo, ["checkout", "-q", "main"])
      tip = peer_pushes!(peer, 1)

      assert {:error, %Error{code: :worktree_create_failed, details: details}} = attach(repo)

      assert details.branch == @branch
      assert details.local == unpushed
      assert details.remote == tip
      # the diverged local branch is exactly as the operator left it
      assert local_sha(repo) == unpushed
    end

    test "a local branch AHEAD of the remote (nothing to fast-forward) is refused too, not reset",
         %{repo: repo, peer: peer} do
      first = peer_pushes!(peer, 1)
      Fix.git!(repo, ["fetch", "-q", "origin", @branch])
      Fix.git!(repo, ["checkout", "-q", "-b", @branch, first])
      ahead = Fix.commit_file!(repo, "ahead.txt", "ahead\n")
      Fix.git!(repo, ["checkout", "-q", "main"])

      assert {:error, %Error{code: :worktree_create_failed}} = attach(repo)
      assert local_sha(repo) == ahead
    end

    test "a force-pushed (rewritten) remote branch does not rewrite the local one",
         %{repo: repo, peer: peer, origin: origin} do
      peer_pushes!(peer, 2)
      assert {:ok, wt} = attach(repo)
      Fix.git!(repo, ["worktree", "remove", "--force", wt.path])
      old_local = local_sha(repo)

      Fix.git!(peer, ["reset", "-q", "--hard", "HEAD~2"])
      rewritten = Fix.commit_file!(peer, "rewritten.txt", "z\n")
      Fix.git!(peer, ["push", "-q", "--force", "origin", @branch])
      assert remote_sha(origin) == rewritten

      assert {:error, %Error{code: :worktree_create_failed}} = attach(repo)
      assert local_sha(repo) == old_local
    end

    test "when the remote branch does not exist the attach fails with the git error",
         %{repo: repo} do
      assert {:error, %Error{code: :git_failed, details: %{remote: "origin", branch: @branch}}} =
               attach(repo)

      assert Fix.git!(repo, ["branch", "--list", @branch]) == ""
    end
  end
end
