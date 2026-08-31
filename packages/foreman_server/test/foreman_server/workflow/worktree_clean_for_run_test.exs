defmodule ForemanServer.Workflow.WorktreeCleanForRunTest do
  @moduledoc """
  Worktree.clean_for_run/1 telemetry coverage.

  Verifies that when git worktree remove fails (e.g., dirty worktree),
  the [:foreman_server, :run, :worktree_cleanup_failed] telemetry event
  is emitted with the failure details.  Prior to this fix, the error was
  silently discarded and the run operator had no indication that cleanup
  failed.
  """
  use ExUnit.Case, async: false

  alias EventStore.EventData
  alias ForemanServer.EventStore
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Workflow.Worktree

  @telemetry_event [:foreman_server, :run, :worktree_cleanup_failed]

  setup do
    repo = Path.join(System.tmp_dir!(), "wt-clean-run-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "seed\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])

    ForemanServer.TestSupport.ProjectionStoreReset.reset!()

    on_exit(fn ->
      ForemanServer.TestSupport.ProjectionStoreReset.reset!()
      File.rm_rf(repo)
    end)

    %{repo: repo, base: head!(repo)}
  end

  describe "telemetry emission on cleanup failure" do
    test "emits event when worktree is dirty", %{repo: repo, base: base} do
      # Use a test-name prefix so aggregate stream IDs are provably distinct.
      run_id = "run-dirty-#{System.unique_integer([:positive])}"
      phase_id = "phase-1"
      operation_id = "wt-dirty-#{run_id}"
      worktree_path = Path.join(repo, ".worktrees/dirty-wt")

      # Create a real git worktree.
      git!(repo, ["worktree", "add", worktree_path, "-b", "foreman/#{run_id}", base])

      # Leave a dirty file so `git worktree remove` would exit 128.
      File.write!(Path.join(worktree_path, "DIRTY"), "uncommitted\n")

      # Seed the projection so clean_for_run/1 can find the worktree.
      seed_worktree(operation_id, run_id, phase_id, worktree_path, base, repo)

      # Attach telemetry handler.
      {handler_id, ref} =
        ForemanServer.TelemetryTest.Handler.attach_event_handlers(self(), [@telemetry_event])

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Worktree.clean_for_run(run_id)

      assert_receive {@telemetry_event, ^ref, measurements, metadata}, 1_000
      assert %{count: 1} = measurements
      assert metadata.run_id == run_id
      assert is_list(metadata.failures)
      assert length(metadata.failures) == 1

      {captured_path, captured_reason} = hd(metadata.failures)
      assert captured_path == worktree_path
      assert {reason_type, _code, _output} = captured_reason
      assert is_atom(reason_type)
    end

    test "emits no telemetry event when all worktrees clean successfully", %{repo: repo, base: base} do
      # Use a test-name prefix so aggregate stream IDs are provably distinct.
      run_id = "run-clean-#{System.unique_integer([:positive])}"
      phase_id = "phase-1"
      operation_id = "wt-clean-#{run_id}"
      worktree_path = Path.join(repo, ".worktrees/clean-wt")

      # Create a real git worktree — no dirty files.
      git!(repo, ["worktree", "add", worktree_path, "-b", "foreman/#{run_id}", base])

      # Seed the projection so clean_for_run/1 can find the worktree.
      seed_worktree(operation_id, run_id, phase_id, worktree_path, base, repo)

      {handler_id, ref} =
        ForemanServer.TelemetryTest.Handler.attach_event_handlers(self(), [@telemetry_event])

      on_exit(fn -> :telemetry.detach(handler_id) end)

      Worktree.clean_for_run(run_id)

      # Expect no failure telemetry.
      refute_receive {@telemetry_event, ^ref, _, _}, 200
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Seed a WorktreeCreated event into the projection store so clean_for_run
  # can find the worktree, and into the VCS aggregate stream so
  # dispatch_worktree_cleaned can append VcsOperationCompleted after the git
  # worktree remove succeeds.
  #
  # aggregate_id = "vcs:#{operation_id}" matches what dispatch_worktree_cleaned
  # uses.  emit_started creates aggregate "vcs_operation:#{operation_id}"
  # (a different aggregate) so we must seed the "vcs:" aggregate directly.
  defp seed_worktree(operation_id, run_id, phase_id, worktree_path, base_ref, repo_path) do
    stream_id = "vcs:#{operation_id}"

    vcs_event = %EventData{
      event_type: "WorktreeCreated",
      data: %{
        operation_id: operation_id,
        project_id: "proj-test",
        run_id: run_id,
        phase_id: phase_id,
        worktree_path: worktree_path,
        repo_path: repo_path,
        branch: "foreman/#{run_id}",
        base_ref: base_ref,
        cleanup: "always"
      }
    }

    # Seed VCS aggregate so exists?: true — dispatch_worktree_cleaned requires it.
    :ok = ForemanServer.EventStore.append_to_stream(stream_id, 0, [vcs_event])

    # Seed projection store so clean_for_run can find the worktree.
    projection_event = %{
      event_type: "WorktreeCreated",
      payload: %{
        operation_id: operation_id,
        project_id: "proj-test",
        run_id: run_id,
        phase_id: phase_id,
        worktree_path: worktree_path,
        repo_path: repo_path,
        branch: "foreman/#{run_id}",
        base_ref: base_ref,
        cleanup: "always"
      }
    }

    assert :ok = ProjectionStore.apply_events([projection_event])
  end

  defp git!(root, args) do
    {_, 0} = System.cmd("git", ["-C", root | args])
  end

  defp head!(root) do
    {sha, 0} = System.cmd("git", ["-C", root, "rev-parse", "--verify", "HEAD"])
    String.trim(sha)
  end
end
