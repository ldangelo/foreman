defmodule ForemanServer.Workflow.RunExecutorFollowUpWorktreeTest do
  # A follow-up run's worktree is attached to the PR's head branch (real git, a bare origin, the
  # production worktree recorder): created at the original path when it is free, or the linked
  # worktree that already holds the branch is reused, and in both cases the run works ON that branch.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor

  @branch "feature/pr-head"

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    root = Path.join(System.tmp_dir!(), "fu-wt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    origin = Path.join(root, "origin.git")
    repo = Path.join(root, "repo")
    git!(root, ["init", "--bare", "-b", "main", origin])
    git!(root, ["clone", origin, repo])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "a.txt"), "one")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-q", "-m", "seed"])
    git!(repo, ["push", "origin", "main"])
    git!(repo, ["checkout", "-q", "-b", @branch])
    File.write!(Path.join(repo, "pr.txt"), "pr work")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-q", "-m", "pr"])
    git!(repo, ["push", "origin", @branch])
    git!(repo, ["checkout", "-q", "main"])
    git!(repo, ["branch", "-D", @branch])

    %{root: root, repo: repo}
  end

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    String.trim(out)
  end

  defp state(repo, followup) do
    %{
      run_id: "run-" <> String.duplicate("b", 32),
      task: %{
        project_id: "proj-fu-wt",
        working_directory: repo,
        provider_tracked: false,
        followup: Map.merge(%{attach_branch: @branch, push: true}, followup)
      },
      worktree_spec: %{cleanup: :never},
      plan_context: nil,
      artifact_base: System.tmp_dir!()
    }
  end

  test "creates the worktree on the PR branch at the original path", %{root: root, repo: repo} do
    original = Path.join(root, "original-worktree")

    assert {:ok, record} =
             RunExecutor.__create_run_worktree_for_test__(
               state(repo, %{worktree_path: original}),
               1
             )

    assert record.worktree_path == original
    assert record.branch == @branch
    assert git!(original, ["rev-parse", "--abbrev-ref", "HEAD"]) == @branch
    assert File.read!(Path.join(original, "pr.txt")) == "pr work"
    assert record.base_ref == git!(original, ["rev-parse", "HEAD"])

    assert [%{worktree_path: ^original, branch: @branch}] = await_worktrees("run-" <> String.duplicate("b", 32))
  end

  test "reuses the linked worktree that already holds the branch", %{root: root, repo: repo} do
    held = Path.join(root, "held")
    git!(repo, ["fetch", "origin", @branch])
    git!(repo, ["worktree", "add", "-b", @branch, held, "origin/#{@branch}"])

    assert {:ok, record} =
             RunExecutor.__create_run_worktree_for_test__(state(repo, %{}), 1)

    # git reports the real path (macOS /var is /private/var)
    assert Path.basename(record.worktree_path) == "held"
    assert File.exists?(Path.join(record.worktree_path, "pr.txt"))
    assert record.branch == @branch
    assert git!(record.worktree_path, ["status", "--porcelain"]) == ""
  end

  test "a branch the project's main checkout is on is refused", %{repo: repo} do
    git!(repo, ["fetch", "origin", @branch])
    git!(repo, ["checkout", "-q", "-b", @branch, "origin/#{@branch}"])

    assert {:error, {:branch_in_main_worktree, @branch}} =
             RunExecutor.__create_run_worktree_for_test__(state(repo, %{}), 1)
  end

  test "a repository the project does not register is refused", %{repo: repo} do
    assert {:error, {:unknown_followup_repo, "/somewhere/else"}} =
             RunExecutor.__create_run_worktree_for_test__(
               state(repo, %{repo_path: "/somewhere/else"}),
               1
             )
  end

  # The recorder's event reaches the projection through the router; read it back until it has.
  defp await_worktrees(run_id, attempts \\ 100) do
    case ProjectionStore.worktrees_for_run(run_id) do
      [] when attempts > 0 ->
        Process.sleep(20)
        await_worktrees(run_id, attempts - 1)

      found ->
        found
    end
  end
end
