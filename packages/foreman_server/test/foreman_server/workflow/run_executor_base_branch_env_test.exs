defmodule ForemanServer.Workflow.RunExecutorBaseBranchEnvTest do
  # `FOREMAN_BASE_BRANCH` is the branch the run's work was cut from, exported
  # to the phase agent so a `review` workflow phase has a correct diff base.
  # `FOREMAN_SOURCE_REVISION` cannot serve this role: it is
  # `worktree_record.base_ref`, refreshed to the shared checkout's HEAD at
  # every phase start, so it equals HEAD on a review phase and yields an
  # empty diff.
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.RunExecutor

  @worktree_record %{
    worktree_path: "/tmp/does-not-matter",
    branch: "foreman/task-x/run-x",
    base_ref: "abc123",
    implementation_key: nil
  }

  defp state(run_base_branch) do
    %{
      run_id: "run-x",
      plan_context: %{},
      task: %{},
      completed: [],
      run_base_branch: run_base_branch
    }
  end

  test "is present when the run's base branch is recorded" do
    env =
      RunExecutor.__foreman_env_for_test__(
        state({:ok, "feat/x"}),
        @worktree_record,
        "/tmp/artifact.md",
        nil
      )

    assert env["FOREMAN_BASE_BRANCH"] == "feat/x"
  end

  test "is absent, not nil, when the run's base branch was never recorded" do
    state = Map.delete(state(nil), :run_base_branch)

    env =
      RunExecutor.__foreman_env_for_test__(
        state,
        @worktree_record,
        "/tmp/artifact.md",
        nil
      )

    refute Map.has_key?(env, "FOREMAN_BASE_BRANCH")
  end

  test "is present with a model, on the model-carrying foreman_env clause" do
    env =
      RunExecutor.__foreman_env_for_test__(
        state({:ok, "main"}),
        @worktree_record,
        "/tmp/artifact.md",
        "MiniMax"
      )

    assert env["FOREMAN_BASE_BRANCH"] == "main"
    assert env["FOREMAN_MODEL"] == "MiniMax"
  end

  test "is absent when the phase has no worktree" do
    env = RunExecutor.__foreman_env_for_test__(state({:ok, "main"}), nil, "/tmp/artifact.md", nil)

    refute Map.has_key?(env, "FOREMAN_BASE_BRANCH")
  end
end
