defmodule ForemanServer.RunArtifacts.BackfillTest do
  @moduledoc """
  The one-shot boot pass that archives the reports recorded before the archive existed
  (`ForemanServer.RunArtifacts.Backfill`): what it archives, what it only counts, that one bad
  report never ends the pass, that a second pass changes nothing, and that the boot child runs
  one pass at the root the server's reader resolves and then stops.

  The pass reads every run the shared projection holds, so each test starts from an empty
  projection and leaves it empty. Reports and archives live in a per-test scratch directory
  (`HOME` is pointed at it for the boot child's own root).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Events.{PhaseCompleted, PhaseStarted}
  alias ForemanServer.{Identity, ProjectionStore, RunArtifacts}
  alias ForemanServer.RunArtifacts.Backfill
  alias ForemanServer.RunArtifacts.Backfill.Summary
  alias ForemanServer.TestSupport.{ProjectionStoreReset, UniqueIds}
  alias ForemanServer.Workflow.RunExecutor

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)

    previous = System.get_env("HOME")
    System.put_env("HOME", Path.join(dir, "home"))

    on_exit(fn ->
      if previous == nil, do: System.delete_env("HOME"), else: System.put_env("HOME", previous)
    end)

    %{base: Path.join(dir, "runs")}
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp report!(dir, name, bytes) do
    path = Path.join(dir, name)
    File.write!(path, bytes)
    path
  end

  # `phases` is `[{index, recorded_path, recorded_sha256}]`: a run whose phases all completed.
  defp seed_run!(run_id, phases) do
    started = %{run_id: run_id, project_id: "p", task_id: "t", workflow_snapshot: %{}}
    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])

    for {index, path, sha256} <- phases do
      phase_id = Identity.phase_id(run_id, index)

      apply!("PhaseStarted", %PhaseStarted{
        phase_id: phase_id,
        run_id: run_id,
        index: index,
        name: "phase-#{index}",
        attempt: 1,
        artifact_template: "{task.projectReportsDir}/report.md",
        input_artifacts: []
      })

      apply!("PhaseCompleted", %PhaseCompleted{
        phase_id: phase_id,
        run_id: run_id,
        index: index,
        artifact_path: path,
        artifact_bytes: 1,
        artifact_sha256: sha256
      })
    end

    :ok
  end

  defp apply!(type, event),
    do: :ok = ProjectionStore.apply_events([%{event_type: type, payload: Map.from_struct(event)}])

  # One pass with its log silenced; the summary it returns.
  defp pass!(base) do
    capture_log(fn -> send(self(), {:summary, Backfill.run(base)}) end)
    assert_received {:summary, {:ok, %Summary{} = summary}}
    summary
  end

  describe "run/1" do
    test "archives what still exists and matches, counts the rest; a second pass changes nothing",
         %{base: base, tmp_dir: dir} do
      run_id = UniqueIds.unique_run_id("backfill")
      matching = report!(dir, "matching.md", "a report that is still where it was recorded")
      edited = report!(dir, "edited.md", "edited after the phase finished")
      held = report!(dir, "held.md", "the recorded file of a phase that is already archived")

      # Phase 4 is archived already, with other bytes: the pass must not read or touch it.
      held_copy = RunArtifacts.archive_path(base, run_id, 4)
      File.mkdir_p!(Path.dirname(held_copy))
      File.write!(held_copy, "an earlier copy")

      seed_run!(run_id, [
        {1, matching, sha(File.read!(matching))},
        {2, Path.join(dir, "reclaimed-worktree.md"), sha("gone")},
        {3, edited, sha("what the phase wrote")},
        {4, held, sha(File.read!(held))}
      ])

      log =
        capture_log(fn ->
          assert {:ok, %Summary{} = summary} = Backfill.run(base)

          assert summary == %Summary{
                   archived: 1,
                   already_archived: 1,
                   missing: 1,
                   mismatched: 1,
                   failed: 0
                 }
        end)

      assert File.read!(RunArtifacts.archive_path(base, run_id, 1)) ==
               "a report that is still where it was recorded"

      refute File.exists?(RunArtifacts.archive_path(base, run_id, 2))
      refute File.exists?(RunArtifacts.archive_path(base, run_id, 3))
      assert File.read!(held_copy) == "an earlier copy"

      # One summary line carries the counts. A report that no longer matches its digest can never be
      # archived, so it is counted but does not warn (it would warn on every boot); a report that is
      # simply gone is the ordinary case: counted, not warned about.
      assert log =~
               "Run artifact backfill: archived 1, already archived 1, missing 1, " <>
                 "mismatched 1, failed 0"

      # The mismatch is logged at debug level with the path and both digests (not as a warning, which
      # would repeat on every boot); the missing report is logged nowhere.
      assert log =~ "run #{run_id} phase 3"
      assert log =~ edited
      assert log =~ sha("what the phase wrote")
      assert log =~ sha("edited after the phase finished")
      refute log =~ "[warning]"
      refute log =~ "run #{run_id} phase 2"

      # Idempotent: what the first pass archived is skipped, the rest is counted as before.
      assert pass!(base) == %Summary{
               archived: 0,
               already_archived: 2,
               missing: 1,
               mismatched: 1,
               failed: 0
             }

      assert held_copy |> Path.dirname() |> File.ls!() |> Enum.sort() == [
               "phase-1.md",
               "phase-4.md"
             ]
    end

    test "a report the pass cannot archive is a warning and does not end the pass", ctx do
      %{base: base, tmp_dir: dir} = ctx
      blocked_run = UniqueIds.unique_run_id("blocked")
      other_run = UniqueIds.unique_run_id("other")
      blocked = report!(dir, "blocked.md", "a report whose archive directory cannot be made")
      other = report!(dir, "other.md", "a report of another run")

      # A regular file where the blocked run's archive directory belongs.
      File.mkdir_p!(Path.join(base, blocked_run))
      File.write!(Path.join([base, blocked_run, "archive"]), "in the way")

      seed_run!(blocked_run, [{1, blocked, sha(File.read!(blocked))}])
      seed_run!(other_run, [{1, other, sha(File.read!(other))}])

      log =
        capture_log(fn ->
          assert {:ok, %Summary{archived: 1, failed: 1, missing: 0, mismatched: 0}} =
                   Backfill.run(base)
        end)

      assert File.read!(RunArtifacts.archive_path(base, other_run, 1)) ==
               "a report of another run"

      assert log =~ "run #{blocked_run} phase 1"
      assert log =~ blocked
      assert log =~ "cannot be written"
      assert log =~ "failed 1"
    end

    test "a run id that cannot name a directory is one failed report; the rest are archived",
         ctx do
      %{base: base, tmp_dir: dir} = ctx
      unsafe_run = UniqueIds.unique_run_id("unsafe") <> "/../escape"
      good_run = UniqueIds.unique_run_id("good")
      unsafe = report!(dir, "unsafe.md", "a report of a run with a hostile id")
      good = report!(dir, "good.md", "a report of a run with an ordinary id")

      seed_run!(unsafe_run, [{1, unsafe, sha(File.read!(unsafe))}])
      seed_run!(good_run, [{1, good, sha(File.read!(good))}])

      log =
        capture_log(fn ->
          assert {:ok, %Summary{archived: 1, failed: 1}} = Backfill.run(base)
        end)

      assert File.read!(RunArtifacts.archive_path(base, good_run, 1)) ==
               "a report of a run with an ordinary id"

      assert log =~ "cannot name an archive directory"
      # Nothing was written anywhere the hostile id pointed.
      refute File.exists?(Path.join(base, "escape"))
      assert File.ls!(base) == [good_run]
    end

    test "a projection that records no report archives nothing and creates nothing", %{base: base} do
      assert pass!(base) == %Summary{
               archived: 0,
               already_archived: 0,
               missing: 0,
               mismatched: 0,
               failed: 0
             }

      refute File.exists?(base)
    end
  end

  describe "the boot child" do
    test "runs one pass at the server's own root, then stops normally", %{tmp_dir: dir} do
      run_id = UniqueIds.unique_run_id("boot")
      recorded = report!(dir, "report.md", "a report from before the archive existed")
      seed_run!(run_id, [{1, recorded, sha(File.read!(recorded))}])

      # The start link delivers the exit signal even when the pass is over before we look.
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          assert {:ok, pid} = Backfill.start_link([])
          assert_receive {:EXIT, ^pid, :normal}, 10_000
        end)

      # The root is the one the executor's state and the HTTP reader start from.
      archived = RunArtifacts.archive_path(RunExecutor.artifact_base(), run_id, 1)

      assert archived ==
               Path.join([dir, "home", ".foreman", "runs", run_id, "archive", "phase-1.md"])

      assert File.read!(archived) == "a report from before the archive existed"
      assert log =~ "Run artifact backfill: archived 1,"
    end

    test "does no work in init/1: the pass runs after the supervisor has its pid", %{tmp_dir: dir} do
      run_id = UniqueIds.unique_run_id("late")
      recorded = report!(dir, "report.md", "report")
      seed_run!(run_id, [{1, recorded, sha("report")}])

      assert {:ok, %{}, {:continue, :backfill}} = Backfill.init([])
      refute File.exists?(RunArtifacts.archive_path(RunExecutor.artifact_base(), run_id, 1))
    end

    test "is a temporary child: whatever happens to it, it is never restarted" do
      assert %{restart: :temporary, start: {Backfill, :start_link, [[]]}} =
               Supervisor.child_spec(Backfill, [])
    end
  end
end
