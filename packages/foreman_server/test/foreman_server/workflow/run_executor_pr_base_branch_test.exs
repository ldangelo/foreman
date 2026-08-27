defmodule ForemanServer.Workflow.RunExecutorPrBaseBranchTest do
  # The PR base branch is the branch the run's work was cut from, read once from
  # the project checkout when the first phase starts. Real git repositories, no
  # mocks: what these assertions read back is exactly the value AutoPR passes to
  # `gh pr create --base`.
  #
  # The defect this pins: `plan_base_branch/1` read
  # `plan_context["base_branch"]`, which nothing writes, and fell back to
  # `"main"`. run-776527010ea5d3568b742adbd25ab872 was cut from
  # `feat/mcp-run-details` and opened PR #420 against `main`, carrying an entire
  # unrelated session of commits.
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.RunExecutor

  setup do
    repo = Path.join(System.tmp_dir!(), "pr-base-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])

    on_exit(fn -> File.rm_rf(repo) end)

    %{repo: repo}
  end

  describe "the recorded base branch is the branch the run was cut from" do
    test "a run cut from a feature branch targets that feature branch", %{repo: repo} do
      git!(repo, ["checkout", "-b", "feat/mcp-run-details", "--quiet"])

      assert run_base_branch(repo) == {:ok, "feat/mcp-run-details"}
    end

    test "a run cut from the default branch still targets the default branch", %{repo: repo} do
      assert run_base_branch(repo) == {:ok, "main"}
    end

    test "the checkout is read once, not re-read as later phases start", %{repo: repo} do
      recorded = RunExecutor.__remember_run_base_branch_for_test__(state(repo))

      # An operator switching the checkout mid-run must not retarget the PR:
      # the base is where the run's work was cut from, not where HEAD is now.
      git!(repo, ["checkout", "-b", "operator/side-quest", "--quiet"])

      assert RunExecutor.__remember_run_base_branch_for_test__(recorded) == recorded
      assert RunExecutor.__run_base_branch_for_test__(recorded) == {:ok, "main"}
    end
  end

  describe "an undeterminable base is a typed failure, never a default" do
    # AGENTS.md 5.2: defaulting here is what produced a PR whose diff belonged
    # to someone else's session, so no branch is a loud error instead.
    test "a detached checkout has no branch to propose against", %{repo: repo} do
      git!(repo, ["checkout", "--detach", "--quiet", "HEAD"])

      assert run_base_branch(repo) ==
               {:error, {:checkout_branch_unresolvable, repo, :detached_head}}
    end

    test "a working directory git cannot read reports git's own complaint" do
      absent = Path.join(System.tmp_dir!(), "no-repo-#{System.unique_integer([:positive])}")

      assert {:error, {:checkout_branch_unresolvable, ^absent, detail}} = run_base_branch(absent)
      # A binary detail, not the `:detached_head` atom: git could not read the
      # directory at all, which is a different failure from a detached HEAD.
      assert is_binary(detail) and detail != ""
    end

    # AGENTS.md 5.3: absent (no phase ever started, so nothing read the
    # checkout) stays distinct from malformed.
    test "a run whose phases never started has nothing recorded" do
      assert RunExecutor.__run_base_branch_for_test__(%{run_id: "run-x"}) ==
               {:error, {:run_base_branch_unrecorded, "run-x"}}
    end
  end

  defp run_base_branch(repo) do
    repo
    |> state()
    |> RunExecutor.__remember_run_base_branch_for_test__()
    |> RunExecutor.__run_base_branch_for_test__()
  end

  defp state(repo), do: %{run_id: "run-x", plan_context: %{"project_root" => repo}}

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root] ++ args, stderr_to_stdout: true)
    output
  end
end
