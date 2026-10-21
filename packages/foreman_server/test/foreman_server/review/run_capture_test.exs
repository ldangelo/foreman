defmodule ForemanServer.Review.RunCaptureTest do
  @moduledoc """
  The workflow door archives a real terminal run, and the Analyzer later
  resolves the SAME archive directory after the worktree-release and terminal
  events have been projected.

  Drives the real `RunExecutor.cleanup_run_worktree/2` (the funnel both
  `finalize_run/1` and `finalize_terminal_and_stop/2` pass through; its first
  statement is `Capture.close_run/2`) against a real git repository and
  worktree, and the real `ProjectionStore`.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Analyzer
  alias ForemanServer.Review.Archive
  alias ForemanServer.Review.Capture
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor

  setup %{tmp_dir: tmp} do
    ProjectionStoreReset.reset!()
    original = Application.get_env(:foreman_server, :review, [])

    Application.put_env(
      :foreman_server,
      :review,
      Keyword.merge(original, capture: true, archive_root: Path.join(tmp, "archive"))
    )

    on_exit(fn ->
      Application.put_env(:foreman_server, :review, original)
      ProjectionStoreReset.reset!()
    end)

    repo = Path.join(tmp, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
    base = git!(repo, ["rev-parse", "HEAD"]) |> String.trim()

    wt = Path.join(tmp, "wt")
    branch = "agent/run-capture"
    git!(repo, ["worktree", "add", "-b", branch, wt, base, "--quiet"])
    File.write!(Path.join(wt, "feature.txt"), "delivered work")
    git!(wt, ["add", "."])
    git!(wt, ["commit", "--no-gpg-sign", "-m", "feature", "--quiet"])

    %{repo: repo, wt: wt, base: base, branch: branch}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", ["-C", dir | args], stderr_to_stdout: true)
    out
  end

  defp seed(run_id, repo, wt, base, branch) do
    task_id = "beads:proj:bd-7"

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "TaskCreated",
                 payload: %{
                   task_id: task_id,
                   project_id: "proj",
                   title: "Add feature",
                   description: "desc",
                   prompt: "Add feature.txt",
                   status: "open",
                   task_type: "task",
                   external_id: "bd-7"
                 }
               },
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: run_id,
                   task_id: task_id,
                   project_id: "proj",
                   workflow_name: "implement"
                 }
               },
               %{
                 event_type: "WorktreeCreated",
                 payload: %{
                   operation_id: "wt-" <> run_id,
                   project_id: "proj",
                   run_id: run_id,
                   phase_id: "#{run_id}-phase-1",
                   repo_path: repo,
                   worktree_path: wt,
                   branch: branch,
                   base_ref: base,
                   cleanup: "never"
                 }
               }
             ])

    %{
      run_id: run_id,
      completed: [0],
      phase_specs: [%{}],
      run_worktree: %{
        operation_id: "wt-" <> run_id,
        worktree_path: wt,
        branch: branch,
        base_ref: base,
        project_root: repo,
        project_id: "proj",
        cleanup: "never"
      }
    }
  end

  for {outcome, terminal, status} <- [
        {:success, "RunCompleted", "completed"},
        {:failure, "RunFailed", "failed"}
      ] do
    test "#{outcome}: archive is written and the Analyzer resolves the same dir after release",
         %{repo: repo, wt: wt, base: base, branch: branch} do
      outcome = unquote(outcome)
      terminal = unquote(terminal)
      status = unquote(status)
      run_id = "run-capture-#{System.unique_integer([:positive])}"
      state = seed(run_id, repo, wt, base, branch)

      assert RunExecutor.__cleanup_run_worktree_for_test__(state, outcome)

      dir = Archive.dir(:run, run_id, repo)
      assert {:ok, manifest} = Archive.read_manifest(dir)
      assert manifest["status"] == status
      assert manifest["bead_id"] == "bd-7"
      assert manifest["project_id"] == "proj"
      assert manifest["base_ref"] == base
      assert manifest["diff_status"] == "captured"
      assert manifest["capture_errors"] == []
      assert File.read!(Path.join(dir, "request.md")) == "Add feature.txt"
      assert File.read!(Path.join(dir, "diff.patch")) =~ "+delivered work"
      assert File.read!(Path.join(dir, "changed-files.txt")) =~ "feature.txt"

      # Worktree release + terminal events are applied AFTER capture.
      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "WorktreeCleaned",
                   payload: %{
                     operation_id: "wt-" <> run_id,
                     project_id: "proj",
                     run_id: run_id,
                     phase_id: "#{run_id}-phase-1",
                     repo_path: repo,
                     worktree_path: wt,
                     cleanup_observed: "removed"
                   }
                 },
                 %{event_type: terminal, payload: %{run_id: run_id, task_id: "beads:proj:bd-7"}}
               ])

      assert [%{status: "cleaned"}] = ProjectionStore.worktrees_for_run(run_id)
      assert {:ok, ^repo} = Capture.run_repo_path(run_id)

      assert {:ok, subject} = Analyzer.subject_from_event(terminal, %{run_id: run_id})
      assert subject.archive_dir == dir
      assert subject.bead_id == "bd-7"
    end
  end

  describe "close_cancelled_run/1" do
    test "archives the retained worktree's working-tree diff with status cancelled",
         %{repo: repo, wt: wt, base: base, branch: branch} do
      run_id = "run-cancel-#{System.unique_integer([:positive])}"
      _ = seed(run_id, repo, wt, base, branch)

      # Work the cancelled agent left behind: an uncommitted edit to a tracked file
      # and a new untracked file (both are part of the diff).
      File.write!(Path.join(wt, "feature.txt"), "delivered work\nleft uncommitted at cancel\n")
      File.write!(Path.join(wt, "scratch.txt"), "untracked scratch\n")

      assert :ok = Capture.close_cancelled_run(run_id)

      dir = Archive.dir(:run, run_id, repo)
      assert {:ok, manifest} = Archive.read_manifest(dir)
      assert manifest["status"] == "cancelled"
      assert manifest["diff_status"] == "captured"
      assert manifest["capture_errors"] == []
      assert manifest["bead_id"] == "bd-7"
      assert manifest["base_ref"] == base
      assert File.read!(Path.join(dir, "request.md")) == "Add feature.txt"

      patch = File.read!(Path.join(dir, "diff.patch"))
      assert patch =~ "+left uncommitted at cancel"
      assert patch =~ "+delivered work"
      assert patch =~ "scratch.txt"
      assert patch =~ "+untracked scratch"
      changed = File.read!(Path.join(dir, "changed-files.txt"))
      assert changed =~ "feature.txt"
      assert changed =~ "scratch.txt"
    end

    test "a run whose worktree projection cannot be diffed is recorded, not raised",
         %{repo: repo} do
      run_id = "run-cancel-nowt-#{System.unique_integer([:positive])}"

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "TaskCreated",
                   payload: %{
                     task_id: "task-" <> run_id,
                     project_id: "proj",
                     title: "T",
                     description: "d",
                     prompt: "do it",
                     status: "open",
                     task_type: "task"
                   }
                 },
                 %{
                   event_type: "RunStarted",
                   payload: %{
                     run_id: run_id,
                     task_id: "task-" <> run_id,
                     project_id: "proj",
                     workflow_name: "implement"
                   }
                 },
                 # Known repo, but no worktree_path/base_ref to diff.
                 %{
                   event_type: "WorktreeCreated",
                   payload: %{
                     operation_id: "wt-" <> run_id,
                     project_id: "proj",
                     run_id: run_id,
                     phase_id: "#{run_id}-phase-1",
                     repo_path: repo
                   }
                 }
               ])

      assert :ok = Capture.close_cancelled_run(run_id)

      dir = Archive.dir(:run, run_id, repo)
      assert {:ok, manifest} = Archive.read_manifest(dir)
      assert manifest["status"] == "cancelled"
      assert manifest["diff_status"] == "unavailable"
      assert [%{"stage" => "diff", "code" => "diff_failed"}] = manifest["capture_errors"]
      refute File.exists?(Path.join(dir, "diff.patch"))
    end
  end

  test "run_repo_path survives a release event that carries no repo_path", %{
    repo: repo,
    wt: wt,
    base: base,
    branch: branch
  } do
    run_id = "run-capture-#{System.unique_integer([:positive])}"
    _ = seed(run_id, repo, wt, base, branch)

    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "WorktreeCleaned",
                 payload: %{
                   operation_id: "wt-" <> run_id,
                   project_id: "proj",
                   run_id: run_id,
                   phase_id: "#{run_id}-phase-1"
                 }
               }
             ])

    assert {:ok, ^repo} = Capture.run_repo_path(run_id)
  end
end
