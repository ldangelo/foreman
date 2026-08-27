defmodule ForemanServer.Workflow.AutoPRTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.AutoPR

  # AutoPR previously had no test coverage at all, which is why nobody noticed
  # that it required a `FOREMAN_COMPLETE` marker no skill ever emitted — so a
  # PR could not land from any workflow, and the failure was invisible because
  # `:noop` was logged at info while the run completed successfully.
  #
  # These tests exercise the real decision logic against a real git repo. The
  # `gh` invocation itself is not exercised (it would hit the network); the
  # boundary tested here is "does AutoPR decide to open a PR, and from which
  # branch".

  setup do
    repo = Path.join(System.tmp_dir!(), "autopr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)

    git = fn args -> System.cmd("git", args, cd: repo, stderr_to_stdout: true) end

    {_, 0} = git.(["init", "--initial-branch=main"])
    {_, 0} = git.(["config", "user.email", "test@example.com"])
    {_, 0} = git.(["config", "user.name", "Test"])
    File.write!(Path.join(repo, "base.txt"), "base\n")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "base"])

    on_exit(fn -> File.rm_rf(repo) end)

    %{repo: repo, git: git}
  end

  defp commit_on_branch(%{repo: repo, git: git}, branch) do
    {_, 0} = git.(["checkout", "-b", branch])
    File.write!(Path.join(repo, "#{branch |> String.replace("/", "-")}.txt"), "work\n")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "work on #{branch}"])
    {_, 0} = git.(["checkout", "main"])
    :ok
  end

  describe "head branch resolution" do
    test "uses the Foreman-derived branch from run state" do
      # The whole point of the rewrite: no artifact, no marker, still resolves.
      ctx = %{
        run_id: "run-1",
        base_branch: "main",
        head_branch: "foreman/run-1/implement",
        cwd: "/nonexistent-so-git-fails"
      }

      # Reaches the git probe, meaning the branch resolved.
      assert {:error, {:rev_list_failed, _, _}} = AutoPR.maybe_create_pr(ctx)
    end

    test "errors when neither run state nor artifact supplies a branch" do
      ctx = %{run_id: "run-1", base_branch: "main", head_branch: nil, cwd: nil}

      assert {:error, :no_head_branch} = AutoPR.maybe_create_pr(ctx)
    end

    test "an artifact FOREMAN_BRANCH marker overrides run state" do
      assert AutoPR.branch_override("noise\nFOREMAN_BRANCH=skill/own-branch\nmore") ==
               "skill/own-branch"
    end

    test "branch_override/1 is nil when the artifact declares no branch" do
      refute AutoPR.branch_override("FOREMAN_COMPLETE=true\nno branch here")
    end
  end

  describe "PR decision is driven by commits, not a marker" do
    test "noop when the head branch has no commits beyond base", %{repo: repo, git: git} do
      {_, 0} = git.(["branch", "foreman/run-2/implement"])

      ctx = %{
        run_id: "run-2",
        base_branch: "main",
        head_branch: "foreman/run-2/implement",
        cwd: repo
      }

      assert AutoPR.maybe_create_pr(ctx) == :noop
    end

    test "attempts a PR when the head branch has commits, with no marker present", ctx do
      commit_on_branch(ctx, "foreman/run-3/implement")

      context = %{
        run_id: "run-3",
        base_branch: "main",
        head_branch: "foreman/run-3/implement",
        cwd: ctx.repo
      }

      # Commits exist, so AutoPR proceeds to `gh pr create`. There is no GitHub
      # remote for this temp repo, so gh fails — the point is that it got past
      # the decision and did NOT silently noop, which is what used to happen.
      assert {:error, {:gh_pr_create_failed, _exit, _output}} = AutoPR.maybe_create_pr(context)
    end

    test "a missing artifact does not prevent a PR", ctx do
      commit_on_branch(ctx, "foreman/run-4/implement")

      context = %{
        run_id: "run-4",
        base_branch: "main",
        head_branch: "foreman/run-4/implement",
        artifact_path: "/definitely/not/a/real/path",
        cwd: ctx.repo
      }

      refute AutoPR.maybe_create_pr(context) == :noop
    end

    test "a git failure is an error, never a silent noop" do
      ctx = %{
        run_id: "run-5",
        base_branch: "main",
        head_branch: "does/not/exist",
        cwd: System.tmp_dir!()
      }

      assert {:error, _} = AutoPR.maybe_create_pr(ctx)
    end
  end

  describe "context validation" do
    test "rejects a context missing required keys" do
      assert {:error, {:invalid_context, _}} = AutoPR.maybe_create_pr(%{run_id: "run-6"})
      assert {:error, {:invalid_context, _}} = AutoPR.maybe_create_pr(%{base_branch: "main"})
    end

    test "rejects a blank base branch" do
      assert {:error, {:invalid_context, _}} =
               AutoPR.maybe_create_pr(%{run_id: "run-7", base_branch: ""})
    end
  end
end
