defmodule ForemanServer.Workflow.PhasePRBodyTest do
  @moduledoc """
  The `## PR body` section of a phase artifact is the PR body verbatim on both
  PR-creating paths (`PhasePR` and the ad-hoc final `AutoPR`); the generated
  template stands whenever it is absent or invalid (AGENTS.md §5.7: one
  extractor, no per-path duplication).
  """

  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.{AutoPR, PhasePR}

  defp temp_artifact!(contents) do
    path = Path.join(System.tmp_dir!(), "phase_pr_body_#{System.unique_integer([:positive])}.md")
    File.write!(path, contents)
    path
  end

  defp phase_body(artifact_path) do
    me = self()

    runner = fn _prog, args ->
      send(me, {:args, args})
      {0, ""}
    end

    {:ok, _} =
      PhasePR.maybe_create(%PhasePR.Request{
        run_id: "run-1",
        phase_id: "run-1:0:repo-rules-review",
        phase_name: "repo-rules-review",
        phase_index: 0,
        head_branch: "foreman/thread-1/run-1",
        base_branch: "dev",
        cwd: "/tmp/does-not-matter",
        artifact_path: artifact_path,
        command_runner: runner
      })

    receive do
      {:args, args} -> Enum.at(args, Enum.find_index(args, &(&1 == "--body")) + 1)
    after
      5_000 -> raise "no gh pr create ran"
    end
  end

  defp auto_body(artifact_path) do
    me = self()

    runner = fn _prog, args ->
      send(me, {:args, args})
      {0, ""}
    end

    {:ok, _} =
      AutoPR.maybe_create_pr(%{
        run_id: "run-1",
        repo_url: "git@github.com:acme/widgets.git",
        head_branch: "fx",
        base_branch: "main",
        worktree_path: "/wt",
        task_title: nil,
        task_description: nil,
        artifact_path: artifact_path,
        command_runner: runner,
        logger: fn _, _ -> :ok end
      })

    receive do
      {:args, args} -> Enum.at(args, Enum.find_index(args, &(&1 == "--body")) + 1)
    after
      5_000 -> raise "no gh pr create ran"
    end
  end

  describe "an agent-written ## PR body section" do
    test "is the PR body verbatim on both paths" do
      artifact =
        temp_artifact!("# Report\n\n## PR body\n\nShips thing.\n\n### Risk\n\nLow.\n")

      body = "Ships thing.\n\n### Risk\n\nLow."
      assert phase_body(artifact) == body
      assert auto_body(artifact) == body
    end

    test "stops at the next level-2 heading" do
      artifact = temp_artifact!("## PR body\n\nOnly this.\n\n## Verification\n\nNot this.\n")
      assert phase_body(artifact) == "Only this."
      assert auto_body(artifact) == "Only this."
    end

    test "is ignored inside a fence, or when repeated, or empty" do
      contents = [
        "````\n## PR body\n\nfenced\n````\n",
        "## PR body\n\nfirst\n\n## PR body\n\nsecond\n",
        "## PR body\n\n \n"
      ]

      for c <- contents do
        artifact = temp_artifact!(c)
        assert phase_body(artifact) =~ "Foreman run `run-1` phase `repo-rules-review` complete."
        assert auto_body(artifact) =~ "Foreman run `run-1` complete."
      end
    end
  end
end
