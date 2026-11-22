defmodule ForemanServer.Workflow.RunExecutorReportArchiveTest do
  @moduledoc """
  `RunExecutor.phase_finish/5` keeps a copy of the phase's report in the run's own directory
  (`ForemanServer.RunArtifacts.archive/5`) before it records `PhaseCompleted`: through the real
  command gateway and projection, the same harness as the phase-input tests of
  `ForemanServer.MCP.RunStatusTest`.

  The report is written outside the artifact base, as one inside the run's git worktree is, so
  the copy is the only thing that survives its removal. `HOME` points at the per-test scratch
  directory, so the executor state's `artifact_base` and the root the server's reader resolves
  are the same directory (as in production) and nothing touches `~/.foreman`.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.{CommandRouter, Identity, ProjectionStore, RunArtifacts}
  alias ForemanServer.Exec.{Context, Step}
  alias ForemanServer.TestSupport.{ProjectionStoreReset, RunSlotsReset, UniqueIds}
  alias ForemanServer.Workflow.{JobsiteObserver, RunExecutor}

  @moduletag :tmp_dir

  @content "# Implementation report\n\nwritten in a worktree that is reclaimed later ✓\n"

  setup %{tmp_dir: dir} do
    :ok = ForemanServer.DispatcherQuiesce.suspend!()
    RunSlotsReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    previous = System.get_env("HOME")
    System.put_env("HOME", Path.join(dir, "home"))

    on_exit(fn ->
      if previous == nil, do: System.delete_env("HOME"), else: System.put_env("HOME", previous)
    end)

    run_id = UniqueIds.unique_run_id("report-archive")
    project_id = "project-#{run_id}"
    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: project_id, path: repo},
        aggregate_id: "project:#{project_id}"
      })

    assert {:ok, started} =
             ForemanServer.RunAdmission.start(project_id, %{
               run_id: run_id,
               task_id: "task-#{run_id}",
               workflow_snapshot: %{phases: []},
               phase_specs: []
             })

    refute started in [:queued, :slot_queued]

    spec = %{name: "first"}

    state = %{
      run_id: run_id,
      task: %{task_id: "task-#{run_id}", project_id: project_id},
      resuming?: false,
      resume_from: 0,
      phase_specs: [spec, %{name: "second"}],
      current_phase: nil,
      status: :ready,
      completed: [],
      phase_statuses: %{},
      worktree_spec: %{enabled: false},
      plan_context: nil,
      artifact_base: RunExecutor.artifact_base()
    }

    # The report of phase 1, where a `{task.projectReportsDir}` template puts it: in the worktree.
    report = Path.join([dir, "worktree", "docs", "reports", "IMPLEMENT_REPORT.md"])
    File.mkdir_p!(Path.dirname(report))
    File.write!(report, @content)

    assert {:ok, state, record} = RunExecutor.phase_begin(state, spec, 0)

    %{run_id: run_id, state: state, spec: spec, record: record, report: report, dir: dir}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp archive_of(%{state: state, run_id: run_id}),
    do: RunArtifacts.archive_path(state.artifact_base, run_id, 1)

  test "keeps the report beside the run's files and still records the original path", ctx do
    %{run_id: run_id, state: state, spec: spec, record: record, report: report} = ctx

    assert {:ok, %{phase_statuses: %{1 => :completed}, completed: [0]}} =
             RunExecutor.phase_finish(state, spec, 0, record, report)

    assert archive_of(ctx) ==
             Path.join([RunExecutor.artifact_base(), run_id, "archive", "phase-1.md"])

    assert File.read!(archive_of(ctx)) == @content
    assert File.ls!(Path.dirname(archive_of(ctx))) == ["phase-1.md"]

    # The projection still records where the phase wrote the report, not the copy.
    assert [%{status: "completed", artifact: artifact}] = ProjectionStore.phases_for_run(run_id)
    assert artifact == %{path: report, sha256: sha(@content), bytes: byte_size(@content)}
  end

  test "the report stays readable once its worktree is gone", ctx do
    %{run_id: run_id, state: state, spec: spec, record: record, report: report} = ctx
    assert {:ok, _} = RunExecutor.phase_finish(state, spec, 0, record, report)

    # The run's worktree is reclaimed.
    File.rm_rf!(Path.join(ctx.dir, "worktree"))
    refute File.exists?(report)

    # The writer used the executor state's root, the reader the server's own: the same one.
    phases = ProjectionStore.phases_for_run(run_id)
    phase_id = Identity.phase_id(run_id, 1)

    assert {:ok,
            %RunArtifacts.Content{
              state: "ok",
              source: "archive",
              sha_matches: true,
              content: @content,
              path: ^report
            }} = RunArtifacts.read(run_id, phase_id, phases)
  end

  test "an archive that cannot be written is a warning, never a failed phase", ctx do
    %{run_id: run_id, state: state, spec: spec, record: record, report: report, dir: dir} = ctx

    # A regular file where the artifact base should be a directory.
    blocker = Path.join(dir, "not-a-directory")
    File.write!(blocker, "a file")
    state = %{state | artifact_base: blocker}

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, %{phase_statuses: %{1 => :completed}, status: :in_progress}} =
                 RunExecutor.phase_finish(state, spec, 0, record, report)
      end)

    # Loud: the run, the phase, the report and the reason are all named.
    assert log =~ "run #{run_id} phase 1"
    assert log =~ report
    assert log =~ "was not archived"
    assert log =~ "cannot be written"

    # And the phase is complete all the same.
    assert [%{status: "completed", artifact: %{path: ^report}}] =
             ProjectionStore.phases_for_run(run_id)

    assert File.read!(report) == @content
  end

  test "a report already inside the archive directory is recorded and left alone", ctx do
    %{state: state, spec: spec, record: record} = ctx
    in_place = archive_of(ctx)
    File.mkdir_p!(Path.dirname(in_place))
    File.write!(in_place, @content)

    log =
      capture_log([level: :warning], fn ->
        assert {:ok, %{phase_statuses: %{1 => :completed}}} =
                 RunExecutor.phase_finish(state, spec, 0, record, in_place)
      end)

    refute log =~ "was not archived"
    assert File.read!(in_place) == @content
    assert File.ls!(Path.dirname(in_place)) == ["phase-1.md"]
  end

  test "the copy is made before PhaseCompleted is recorded: a refused completion still leaves it",
       ctx do
    %{run_id: run_id, state: state, report: report} = ctx
    never_started = %{name: "second"}

    # Phase 2 was never started, so the aggregate refuses `phase.complete` for it.
    capture_log(fn ->
      assert {:error, _refused} = RunExecutor.phase_finish(state, never_started, 1, nil, report)
    end)

    refute Enum.any?(ProjectionStore.phases_for_run(run_id), &(&1.status == "completed"))

    assert File.read!(RunArtifacts.archive_path(state.artifact_base, run_id, 2)) == @content
  end

  test "the engine's commit step reaches it through the observer", ctx do
    %{run_id: run_id, state: state, spec: spec, record: record, report: report, dir: dir} = ctx

    observer = %{
      executor: state,
      phase: %{idx: 0, spec: spec, number: 1, record: record, body?: true, artifact_path: report}
    }

    jobsite_ctx = %Context{jobsite_id: "jobsite-#{run_id}", repo_path: Path.join(dir, "repo")}
    step = %Step{kind: :commit, id: "commit-1", opts: %{phase_idx: 0}}

    assert {:ok, %Context{}, %{phase: nil, executor: executor}} =
             JobsiteObserver.step_completed(step, jobsite_ctx, {:commit, :no_worktree}, observer)

    assert executor.phase_statuses == %{1 => :completed}
    assert File.read!(archive_of(ctx)) == @content
  end
end
