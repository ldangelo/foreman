defmodule ForemanServer.ProjectionStoreWorktreesTest do
  @moduledoc """
  ProjectionStore worktrees slice:

  - WorktreeCreated → upsert into `state.worktrees` keyed by operation_id
    with status "created" and the workflow-resolved metadata (worktree_path,
    branch, base_ref, cleanup).
  - WorktreeCleaned → upsert the same key with status "cleaned" plus
    `cleanup_observed`, preserving previously recorded correlation metadata.
  - Query helpers `worktree/1`, `worktrees_for_run/1`, and
    `worktree_for_phase/3` return the projected entry (or empty list / nil)
  and are stable against the deterministic `operation_id` derivation.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore

  setup do
    # Be defensive against any prior test file that may have left the
    # ProjectionStore in a partial shape (missing keys like
    # `:project_active_runs` or `:run_slots`). The full reset helper
    # always seeds every key the production `initial_state/0` defines.
    ForemanServer.TestSupport.ProjectionStoreReset.reset!()

    on_exit(fn ->
      ForemanServer.TestSupport.ProjectionStoreReset.reset!()
    end)

    :ok
  end

  describe "WorktreeCreated" do
    test "upserts into state.worktrees keyed by operation_id" do
      operation_id = "wt-run-1-phase-a"

      payload = %{
        operation_id: operation_id,
        project_id: "proj-1",
        run_id: "run-1",
        phase_id: "phase-a",
        worktree_path: "/repos/proj-1/.worktrees/wt-run-1-phase-a",
        branch: "feat/phase-a",
        base_ref: "abc123",
        cleanup: "always"
      }

      assert :ok =
               ProjectionStore.apply_events([%{event_type: "WorktreeCreated", payload: payload}])

      assert %{
               operation_id: ^operation_id,
               project_id: "proj-1",
               run_id: "run-1",
               phase_id: "phase-a",
               status: "created",
               worktree_path: "/repos/proj-1/.worktrees/wt-run-1-phase-a",
               branch: "feat/phase-a",
               base_ref: "abc123",
               cleanup: "always"
             } = ProjectionStore.worktree(operation_id)
    end

    test "accepts optional worktree configuration fields as nil" do
      operation_id = "wt-run-2-phase-b"

      payload = %{
        operation_id: operation_id,
        project_id: "proj-1",
        run_id: "run-2",
        phase_id: "phase-b",
        worktree_path: nil,
        branch: nil,
        base_ref: nil,
        cleanup: nil
      }

      assert :ok =
               ProjectionStore.apply_events([%{event_type: "WorktreeCreated", payload: payload}])

      assert %{
               status: "created",
               worktree_path: nil,
               branch: nil,
               base_ref: nil,
               cleanup: nil
             } = ProjectionStore.worktree(operation_id)
    end

    test "ignores events with empty operation_id" do
      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "WorktreeCreated",
                   payload: %{
                     operation_id: "",
                     project_id: "proj",
                     run_id: "run",
                     phase_id: "phase"
                   }
                 }
               ])

      assert ProjectionStore.worktree("") == nil
    end
  end

  describe "WorktreeCleaned" do
    test "transitions status to 'cleaned' and records cleanup_observed" do
      operation_id = "wt-run-3-phase-c"

      created = %{
        operation_id: operation_id,
        project_id: "proj-2",
        run_id: "run-3",
        phase_id: "phase-c",
        worktree_path: "/repos/proj-2/.worktrees/wt-run-3-phase-c",
        branch: "feat/phase-c",
        base_ref: "def456",
        cleanup: "always"
      }

      assert :ok =
               ProjectionStore.apply_events([%{event_type: "WorktreeCreated", payload: created}])

      cleaned_payload = %{
        operation_id: operation_id,
        project_id: "proj-2",
        run_id: "run-3",
        phase_id: "phase-c",
        worktree_path: "/repos/proj-2/.worktrees/wt-run-3-phase-c",
        cleanup_observed: "removed"
      }

      assert :ok =
               ProjectionStore.apply_events([
                 %{event_type: "WorktreeCleaned", payload: cleaned_payload}
               ])

      assert %{
               operation_id: ^operation_id,
               project_id: "proj-2",
               run_id: "run-3",
               phase_id: "phase-c",
               status: "cleaned",
               cleanup_observed: "removed",
               # Preserved from the prior WorktreeCreated entry
               branch: "feat/phase-c",
               base_ref: "def456"
             } = ProjectionStore.worktree(operation_id)
    end

    test "cleaned event without prior create records correlation only" do
      operation_id = "wt-run-orphan-phase"

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "WorktreeCleaned",
                   payload: %{
                     operation_id: operation_id,
                     project_id: "proj-orphan",
                     run_id: "run-orphan",
                     phase_id: "phase-orphan",
                     worktree_path: nil,
                     cleanup_observed: "missing"
                   }
                 }
               ])

      assert %{
               operation_id: ^operation_id,
               status: "cleaned",
               cleanup_observed: "missing",
               worktree_path: nil
             } = ProjectionStore.worktree(operation_id)
    end
  end

  describe "worktree/1" do
    test "returns nil for unknown operation_id" do
      assert ProjectionStore.worktree("wt-nope") == nil
    end
  end

  describe "worktrees_for_run/1" do
    test "returns every worktree for a given run, sorted by operation_id" do
      run_id = "run-list"

      entries = [
        %{
          operation_id: "wt-#{run_id}-phase-c",
          project_id: "p",
          run_id: run_id,
          phase_id: "phase-c",
          worktree_path: "/r/.worktrees/c",
          branch: nil,
          base_ref: nil,
          cleanup: nil
        },
        %{
          operation_id: "wt-#{run_id}-phase-a",
          project_id: "p",
          run_id: run_id,
          phase_id: "phase-a",
          worktree_path: "/r/.worktrees/a",
          branch: nil,
          base_ref: nil,
          cleanup: nil
        },
        %{
          operation_id: "wt-#{run_id}-phase-b",
          project_id: "p",
          run_id: run_id,
          phase_id: "phase-b",
          worktree_path: "/r/.worktrees/b",
          branch: nil,
          base_ref: nil,
          cleanup: nil
        }
      ]

      events = Enum.map(entries, &%{event_type: "WorktreeCreated", payload: &1})
      assert :ok = ProjectionStore.apply_events(events)

      op_a = "wt-#{run_id}-phase-a"
      op_b = "wt-#{run_id}-phase-b"
      op_c = "wt-#{run_id}-phase-c"

      result = ProjectionStore.worktrees_for_run(run_id)

      assert Enum.map(result, & &1.operation_id) == [op_a, op_b, op_c]
    end

    test "returns empty list when run has no worktrees" do
      assert ProjectionStore.worktrees_for_run("run-without-worktrees") == []
    end
  end

  describe "worktree_for_phase/3" do
    test "derives the deterministic operation_id and returns the projected entry" do
      project_id = "proj-phase"
      run_id = "run-phase"
      phase_id = "phase-derived"
      operation_id = "wt-#{run_id}-#{phase_id}"

      payload = %{
        operation_id: operation_id,
        project_id: project_id,
        run_id: run_id,
        phase_id: phase_id,
        worktree_path: "/repos/#{project_id}/.worktrees/#{operation_id}",
        branch: "feat/#{phase_id}",
        base_ref: "sha",
        cleanup: "always"
      }

      assert :ok =
               ProjectionStore.apply_events([%{event_type: "WorktreeCreated", payload: payload}])

      assert %{
               operation_id: ^operation_id,
               project_id: ^project_id,
               run_id: ^run_id,
               phase_id: ^phase_id
             } = ProjectionStore.worktree_for_phase(project_id, run_id, phase_id)
    end

    test "returns nil when the phase has no recorded worktree" do
      assert ProjectionStore.worktree_for_phase("proj", "run", "missing") == nil
    end
  end

  describe "rebuild from full event log (restart-discoverability)" do
    # The plan's restart-discoverability contract: after a Foreman restart,
    # BootReconciliation enumerates every worktree whose `WorktreeCreated`
    # event was persisted but whose `WorktreeCleaned` was not. The
    # projection must rebuild from the persisted EventStore — not from
    # in-memory `apply_events/1` — so these tests persist real events
    # via `TestRouter.dispatch/1` (the only EventStore writer allowed by
    # architecture enforcement), then call `ProjectionStore.rebuild/1`
    # to force the projection to re-read the event log from scratch.
    #
    # `ProjectionStore.rebuild/1` re-reads `EventStore.read_all_streams_forward`
    # internally, so the events we append below are exactly what the
    # boot-time replay will see.

    alias ForemanServer.TestSupport.TestRouter

    test "surfaces only created-without-clean entries via list_unresolved_worktrees/0" do
      run_id = "run-rebuild-#{System.unique_integer([:positive])}"

      resolved_op = "wt-#{run_id}-phase-done"
      orphan_op = "wt-#{run_id}-phase-orphan"

      assert {:ok, _} = TestRouter.dispatch(build_create_cmd(resolved_op, run_id, "phase-done"))
      assert {:ok, _} = TestRouter.dispatch(build_clean_cmd(resolved_op, run_id, "phase-done"))
      assert {:ok, _} = TestRouter.dispatch(build_create_cmd(orphan_op, run_id, "phase-orphan"))

      assert :ok = ProjectionStore.rebuild([])

      # Only this test's orphan should appear among unresolved entries that
      # match our run_id; the resolved one must surface as cleaned. Other
      # unrelated worktrees may exist in $all from sibling tests sharing
      # the test database, so we scope to this run_id to isolate the
      # restart-discoverability contract we own.
      ours =
        ProjectionStore.list_unresolved_worktrees()
        |> Enum.filter(fn %{run_id: rid} -> rid == run_id end)

      assert [%{operation_id: ^orphan_op}] = ours

      assert %{status: "cleaned"} = ProjectionStore.worktree(resolved_op)
      assert %{status: "created", operation_id: ^orphan_op} = ProjectionStore.worktree(orphan_op)
    end

    test "multiple orphans across runs are all surfaced, sorted by operation_id" do
      run1 = "run-r1-#{System.unique_integer([:positive])}"
      run2 = "run-r2-#{System.unique_integer([:positive])}"
      orphan_a = "wt-#{run1}-phase-a"
      orphan_b = "wt-#{run2}-phase-a"
      orphan_c = "wt-#{run1}-phase-b"

      assert {:ok, _} = TestRouter.dispatch(build_create_cmd(orphan_a, run1, "phase-a"))
      assert {:ok, _} = TestRouter.dispatch(build_create_cmd(orphan_b, run2, "phase-a"))
      assert {:ok, _} = TestRouter.dispatch(build_create_cmd(orphan_c, run1, "phase-b"))
      assert {:ok, _} = TestRouter.dispatch(build_clean_cmd(orphan_a, run1, "phase-a"))

      assert :ok = ProjectionStore.rebuild([])

      # Scope to this test's runs so unrelated orphans from sibling tests
      # sharing the database don't pollute the assertion. Within that
      # scope, the two uncleaned operations must come back sorted by
      # operation_id (the contract BootReconciliation depends on).
      ours =
        ProjectionStore.list_unresolved_worktrees()
        |> Enum.filter(fn %{run_id: rid} -> rid in [run1, run2] end)

      assert [%{operation_id: op1}, %{operation_id: op2}] =
               Enum.sort_by(ours, & &1.operation_id)

      assert [op1, op2] == Enum.sort([orphan_b, orphan_c])
    end
  end

  defp build_create_cmd(operation_id, run_id, phase_id) do
    %{
      command_id: "test-cmd-#{operation_id}-create",
      aggregate_id: "vcs:#{operation_id}",
      type: "vcs.worktree.create",
      payload: %{
        operation_id: operation_id,
        project_id: "proj-#{run_id}",
        run_id: run_id,
        phase_id: phase_id,
        worktree_path: "/repos/proj-#{run_id}/.worktrees/#{operation_id}",
        branch: "feat/#{phase_id}",
        base_ref: "sha",
        cleanup: "always"
      }
    }
  end

  defp build_clean_cmd(operation_id, run_id, phase_id) do
    %{
      command_id: "test-cmd-#{operation_id}-clean",
      aggregate_id: "vcs:#{operation_id}",
      type: "vcs.worktree.clean",
      payload: %{
        operation_id: operation_id,
        project_id: "proj-#{run_id}",
        run_id: run_id,
        phase_id: phase_id,
        cleanup_observed: "removed"
      }
    }
  end
end
