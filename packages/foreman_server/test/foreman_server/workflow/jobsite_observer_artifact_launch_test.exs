defmodule ForemanServer.Workflow.JobsiteObserverArtifactLaunchTest do
  @moduledoc """
  What lets `ArtifactTemplate.write/5` keep the agent's report is the snapshot the observer takes of
  the artifact path when the phase's agent launches. `JobsiteObserverArtifactTest` hands the observer
  that snapshot; here the observer takes it. The agent step runs in the engine's order (`step_started`
  on the first iteration, which builds the real launch from the executor state `RunExecutor.init/1`
  makes, then `step_completed` once the agent is done), so a snapshot that is never taken, is taken
  from another path or is taken after the agent ran fails a test below.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Exec.{Context, Step}
  alias ForemanServer.TestSupport.UniqueIds
  alias ForemanServer.Workflow.{JobsiteObserver, PhaseSpec, ReviewFindings, RunExecutor}

  @moduletag :tmp_dir
  # The launch warns that the made-up project has no registered context.
  @moduletag :capture_log

  @block """
  <!-- FOREMAN_REVIEW_FINDINGS_START -->
  {"schema":"foreman.review_findings/1","reviewed":true,"findings":[]}
  <!-- FOREMAN_REVIEW_FINDINGS_END -->
  """

  @report "# Review\n\nLooks fine.\n\n" <> @block
  @earlier "# Review\n\nAn earlier attempt's report.\n"
  @chat "Review complete; see the report."

  # Phase 0 declares an `artifact:` template; phase 1 declares none, so its report is the default
  # `<artifact_base>/<run_id>/phase-<number>.md`, a path that is a function of the phase NUMBER.
  setup %{tmp_dir: dir} do
    run_id = UniqueIds.unique_run_id("observer-artifact")
    templated = Path.join(dir, "docs/reports/REVIEW_REPORT.md")

    projection = %{
      task_id: "task-#{run_id}",
      project_id: "project-#{run_id}",
      working_directory: dir,
      workflow_type: "implement",
      workflow_snapshot: %{
        "workflow_name" => "implement",
        "workflow_digest" => "digest-observer-artifact",
        "worktree" => %{"enabled" => false},
        "phases" => [
          %{"name" => "templated", "artifact" => templated},
          %{"name" => "untemplated"}
        ]
      }
    }

    {:ok, executor} = RunExecutor.init({run_id, projection, []})
    executor = %{executor | artifact_base: Path.join(dir, "runs")}
    defaulted = Path.join([executor.artifact_base, run_id, "phase-2.md"])

    for path <- [templated, defaulted], do: File.mkdir_p!(Path.dirname(path))

    %{executor: executor, templated: templated, defaulted: defaulted}
  end

  # One agent step in the engine's order: `step_started` on iteration 1 (the launch, where the
  # observer snapshots the artifact path), the agent runs (`while_agent_runs`), `step_completed`.
  defp run_agent(executor, idx, while_agent_runs) do
    spec = Enum.at(executor.phase_specs, idx)

    observer = %{
      executor: executor,
      phase: %{
        idx: idx,
        spec: spec,
        number: PhaseSpec.number(spec, idx),
        record: nil,
        body?: true,
        artifact_path: nil,
        artifact_baseline: nil
      }
    }

    ctx = %Context{jobsite_id: "jobsite-observer-artifact", repo_path: "/unused"}
    step = %Step{kind: :agent, id: "agent-#{idx}", opts: %{phase_idx: idx, iteration_index: 1}}

    assert {:ok, observer, %{launch: _launch}} = JobsiteObserver.step_started(step, ctx, observer)

    while_agent_runs.()

    assert {:ok, %Context{artifact_path: path}, _observer} =
             JobsiteObserver.step_completed(step, ctx, {:agent, [%{text: @chat}]}, observer)

    path
  end

  test "a report the agent writes while it runs is kept and parses", ctx do
    assert run_agent(ctx.executor, 0, fn -> File.write!(ctx.templated, @report) end) ==
             ctx.templated

    assert File.read!(ctx.templated) == @report
    assert {:recorded, _} = ReviewFindings.parse(File.read!(ctx.templated))
  end

  test "a report an earlier attempt left is replaced when the agent does not touch it", ctx do
    File.write!(ctx.templated, @earlier)

    assert run_agent(ctx.executor, 0, fn -> :ok end) == ctx.templated
    assert File.read!(ctx.templated) == @chat
  end

  test "a report the agent rewrites over an earlier attempt's is kept", ctx do
    File.write!(ctx.templated, @earlier)

    assert run_agent(ctx.executor, 0, fn -> File.write!(ctx.templated, @report) end) ==
             ctx.templated

    assert File.read!(ctx.templated) == @report
  end

  test "no report from the agent leaves its final message as the artifact", ctx do
    assert run_agent(ctx.executor, 0, fn -> :ok end) == ctx.templated
    assert File.read!(ctx.templated) == @chat
  end

  describe "a phase with no artifact template" do
    test "the default path is snapshotted by the phase number, so an earlier file there is replaced",
         ctx do
      File.write!(ctx.defaulted, @earlier)

      assert run_agent(ctx.executor, 1, fn -> :ok end) == ctx.defaulted
      assert File.read!(ctx.defaulted) == @chat
    end

    test "a report the agent writes to it is kept", ctx do
      File.write!(ctx.defaulted, @earlier)

      assert run_agent(ctx.executor, 1, fn -> File.write!(ctx.defaulted, @report) end) ==
               ctx.defaulted

      assert File.read!(ctx.defaulted) == @report
    end
  end
end
