defmodule ForemanServer.Workflow.AttachBranchTest do
  # A follow-up run attaches to a PR's head branch: the local branch is brought to the remote tip
  # (fast-forward only), a linked worktree holding it is reused, the main worktree is refused, and
  # the run publishes with a plain push that the remote refuses unless it is a fast-forward.
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.{AttachBranch, RunExecutor}

  @branch "feature/x"

  setup do
    root = Path.join(System.tmp_dir!(), "attach-branch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    origin = Path.join(root, "origin.git")
    repo = Path.join(root, "repo")
    git!(root, ["init", "--bare", "-b", "main", origin])
    git!(root, ["clone", origin, repo])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "T"])
    commit!(repo, "a.txt", "one")
    git!(repo, ["push", "origin", "main"])
    git!(repo, ["checkout", "-b", @branch])
    commit!(repo, "b.txt", "pr work")
    git!(repo, ["push", "origin", @branch])
    # the operator's live checkout is on main, never on the PR branch
    git!(repo, ["checkout", "main"])
    git!(repo, ["branch", "-D", @branch])

    {:ok, root: root, origin: origin, repo: repo, default_path: Path.join(root, "run-worktree")}
  end

  defp git!(cwd, args) do
    {out, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    out
  end

  defp commit!(cwd, file, text) do
    File.write!(Path.join(cwd, file), text)
    git!(cwd, ["add", file])
    git!(cwd, ["commit", "-q", "-m", "add #{file}"])
  end

  defp remote_tip(repo), do: git!(repo, ["rev-parse", "origin/#{@branch}"]) |> String.trim()

  test "a branch no worktree holds is created at the remote tip, at the free hint path", ctx do
    hint = Path.join(ctx.root, "original-worktree")

    assert {:ok, %{mode: :create, path: ^hint, tip: tip}} =
             AttachBranch.prepare(ctx.repo, @branch, "origin",
               default_path: ctx.default_path,
               hint_path: hint
             )

    assert tip == remote_tip(ctx.repo)
    assert git!(ctx.repo, ["rev-parse", @branch]) |> String.trim() == tip
  end

  test "a hint path that exists falls back to the run's own path", ctx do
    taken = Path.join(ctx.root, "taken")
    File.mkdir_p!(taken)

    assert {:ok, %{mode: :create, path: path}} =
             AttachBranch.prepare(ctx.repo, @branch, "origin",
               default_path: ctx.default_path,
               hint_path: taken
             )

    assert path == ctx.default_path
  end

  test "a linked worktree that holds the branch is reused as it stands", ctx do
    held = Path.join(ctx.root, "held")
    git!(ctx.repo, ["fetch", "origin", @branch])
    git!(ctx.repo, ["worktree", "add", "-b", @branch, held, "origin/#{@branch}"])

    assert {:ok, %{mode: :reuse, path: path}} =
             AttachBranch.prepare(ctx.repo, @branch, "origin", default_path: ctx.default_path)

    assert Path.basename(path) == "held"
  end

  test "a branch behind the remote is fast-forwarded", ctx do
    held = Path.join(ctx.root, "held")
    git!(ctx.repo, ["fetch", "origin", @branch])
    git!(ctx.repo, ["worktree", "add", "-b", @branch, held, "origin/#{@branch}"])

    # someone else pushes to the PR branch
    other = Path.join(ctx.root, "other")
    git!(ctx.root, ["clone", "-b", @branch, ctx.origin, other])
    git!(other, ["config", "user.email", "o@example.com"])
    git!(other, ["config", "user.name", "O"])
    commit!(other, "c.txt", "reviewer push")
    git!(other, ["push", "origin", @branch])

    assert {:ok, %{mode: :reuse, tip: tip}} =
             AttachBranch.prepare(ctx.repo, @branch, "origin", default_path: ctx.default_path)

    assert git!(held, ["rev-parse", "HEAD"]) |> String.trim() == tip
    assert File.exists?(Path.join(held, "c.txt"))
  end

  test "local commits the remote lacks are refused, never discarded", ctx do
    held = Path.join(ctx.root, "held")
    git!(ctx.repo, ["fetch", "origin", @branch])
    git!(ctx.repo, ["worktree", "add", "-b", @branch, held, "origin/#{@branch}"])
    commit!(held, "local.txt", "unpushed")

    assert {:error, {:attach_failed, :worktree_create_failed, message}} =
             AttachBranch.prepare(ctx.repo, @branch, "origin", default_path: ctx.default_path)

    assert message =~ "unpushed"
    assert File.exists?(Path.join(held, "local.txt"))
  end

  test "the repository's main worktree is refused", ctx do
    git!(ctx.repo, ["fetch", "origin", @branch])
    git!(ctx.repo, ["checkout", "-b", @branch, "origin/#{@branch}"])

    assert {:error, {:branch_in_main_worktree, @branch}} =
             AttachBranch.prepare(ctx.repo, @branch, "origin", default_path: ctx.default_path)
  end

  test "publishing pushes the attached branch only, and a rejected push fails", ctx do
    path = ctx.default_path
    assert {:ok, %{tip: tip}} =
             AttachBranch.prepare(ctx.repo, @branch, "origin", default_path: path)

    git!(ctx.repo, ["worktree", "add", path, @branch])
    git!(path, ["config", "user.email", "t@example.com"])
    git!(path, ["config", "user.name", "T"])
    commit!(path, "fix.txt", "the fix")

    state = %{
      run_id: "run-pub",
      task: %{followup: %{attach_branch: @branch, push: true}},
      run_worktree: %{worktree_path: path, branch: @branch}
    }

    assert :ok = RunExecutor.__publish_followup_for_test__(state)
    refute remote_tip(ctx.repo) == tip
    assert git!(ctx.origin, ["rev-parse", @branch]) |> String.trim() ==
             git!(path, ["rev-parse", "HEAD"]) |> String.trim()

    # a reviewer pushes meanwhile: our next push is not a fast-forward and is refused
    other = Path.join(ctx.root, "other")
    git!(ctx.root, ["clone", "-b", @branch, ctx.origin, other])
    git!(other, ["config", "user.email", "o@example.com"])
    git!(other, ["config", "user.name", "O"])
    commit!(other, "r.txt", "reviewer")
    git!(other, ["push", "origin", @branch])
    commit!(path, "more.txt", "late fix")

    assert {:error, {:followup_push_failed, @branch, _}} =
             RunExecutor.__publish_followup_for_test__(state)
  end

  test "a run that is not a follow-up publishes nothing" do
    assert :ok = RunExecutor.__publish_followup_for_test__(%{run_id: "r", task: %{}})
    assert :ok = RunExecutor.__publish_followup_for_test__(%{run_id: "r", task: %{followup: %{push: false, attach_branch: "x"}}})
  end
end
