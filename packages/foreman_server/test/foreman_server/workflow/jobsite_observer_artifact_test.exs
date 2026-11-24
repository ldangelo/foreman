defmodule ForemanServer.Workflow.JobsiteObserverArtifactTest do
  # The review phases tell the agent to write `REVIEW_REPORT.md` with a
  # machine-read findings block. The observer used to replace that file with
  # the agent's final chat message, so every PR read `findings_absent`.
  use ExUnit.Case, async: true

  alias ForemanServer.Exec.{Context, Step}
  alias ForemanServer.Workflow.{JobsiteObserver, ReviewFindings}

  @moduletag :tmp_dir

  @block """
  <!-- FOREMAN_REVIEW_FINDINGS_START -->
  {"schema":"foreman.review_findings/1","reviewed":true,"findings":[]}
  <!-- FOREMAN_REVIEW_FINDINGS_END -->
  """

  @report "# Review\n\nLooks fine.\n\n" <> @block
  @chat "Review complete; see the report."

  setup %{tmp_dir: dir} do
    report = Path.join(dir, "docs/reports/REVIEW_REPORT.md")
    spec = %{name: "repo-rules-review", artifact_template: report}

    executor = %{
      run_id: "run-obs",
      task: %{task_id: "task-obs"},
      artifact_base: Path.join(dir, "runs")
    }

    observer = %{
      executor: executor,
      phase: %{
        idx: 0,
        spec: spec,
        number: 1,
        record: nil,
        body?: true,
        artifact_path: nil,
        artifact_baseline: {:snapshot, nil}
      }
    }

    File.mkdir_p!(Path.dirname(report))
    %{report: report, observer: observer}
  end

  defp with_baseline(observer, fingerprint),
    do: put_in(observer.phase.artifact_baseline, {:snapshot, fingerprint})

  defp complete_agent(observer) do
    step = %Step{kind: :agent, id: "agent-1", opts: %{phase_idx: 0, iteration_index: 1}}
    ctx = %Context{jobsite_id: "jobsite-obs", repo_path: "/unused"}
    iterations = [%{text: @chat}]

    assert {:ok, %Context{artifact_path: path}, _state} =
             JobsiteObserver.step_completed(step, ctx, {:agent, iterations}, observer)

    path
  end

  test "the report the agent wrote survives the agent step and still parses", ctx do
    File.write!(ctx.report, @report)

    assert complete_agent(ctx.observer) == ctx.report
    assert File.read!(ctx.report) == @report
    assert {:recorded, _} = ReviewFindings.parse(File.read!(ctx.report))
  end

  test "with no file from the agent, its final message becomes the artifact", ctx do
    assert complete_agent(ctx.observer) == ctx.report
    assert File.read!(ctx.report) == @chat
  end

  test "a file the agent left untouched is replaced by this attempt's final message", ctx do
    # Left by an earlier attempt or phase, and even freshly touched by a checkout.
    File.write!(ctx.report, @report)
    stale = ForemanServer.Identity.sha256(@report)
    observer = with_baseline(ctx.observer, stale)

    assert complete_agent(observer) == ctx.report
    assert File.read!(ctx.report) == @chat
  end

  test "a file the agent rewrote over an earlier one is kept", ctx do
    File.write!(ctx.report, @report)
    older = ForemanServer.Identity.sha256("an earlier attempt's report")
    observer = with_baseline(ctx.observer, older)

    assert complete_agent(observer) == ctx.report
    assert File.read!(ctx.report) == @report
  end

  test "an empty file is replaced by the final message", ctx do
    File.write!(ctx.report, "")
    assert complete_agent(ctx.observer) == ctx.report
    assert File.read!(ctx.report) == @chat
  end
end
