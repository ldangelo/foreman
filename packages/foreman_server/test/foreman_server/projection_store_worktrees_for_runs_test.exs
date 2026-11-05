defmodule ForemanServer.ProjectionStoreWorktreesForRunsTest do
  @moduledoc """
  `ProjectionStore.worktrees_for_runs/1` returns, for every requested run id,
  exactly what `worktrees_for_run/1` returns for it.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore

  setup do
    ForemanServer.TestSupport.ProjectionStoreReset.reset!()
    on_exit(fn -> ForemanServer.TestSupport.ProjectionStoreReset.reset!() end)
    :ok
  end

  defp created(run_id, phase_id) do
    %{
      event_type: "WorktreeCreated",
      payload: %{
        operation_id: "wt-#{run_id}-#{phase_id}",
        project_id: "proj-1",
        run_id: run_id,
        phase_id: phase_id,
        worktree_path: "/repos/proj-1/.worktrees/wt-#{run_id}-#{phase_id}",
        branch: "feat/#{phase_id}",
        base_ref: "abc123",
        cleanup: "always"
      }
    }
  end

  defp cleaned(run_id, phase_id) do
    %{
      event_type: "WorktreeCleaned",
      payload: %{
        operation_id: "wt-#{run_id}-#{phase_id}",
        project_id: "proj-1",
        run_id: run_id,
        phase_id: phase_id,
        worktree_path: "/repos/proj-1/.worktrees/wt-#{run_id}-#{phase_id}",
        cleanup_observed: "removed"
      }
    }
  end

  test "bulk read equals the per-run read for every run, in operation_id order" do
    # Seeded out of operation_id order so the sort is exercised.
    assert :ok =
             ProjectionStore.apply_events([
               created("run-a", "phase-b"),
               created("run-b", "phase-a"),
               created("run-a", "phase-a"),
               cleaned("run-a", "phase-b")
             ])

    result = ProjectionStore.worktrees_for_runs(["run-a", "run-b"])

    assert Map.keys(result) |> Enum.sort() == ["run-a", "run-b"]

    for run_id <- ["run-a", "run-b"] do
      assert result[run_id] == ProjectionStore.worktrees_for_run(run_id)
    end

    assert Enum.map(result["run-a"], & &1.operation_id) == [
             "wt-run-a-phase-a",
             "wt-run-a-phase-b"
           ]

    assert Enum.map(result["run-a"], & &1.status) == ["created", "cleaned"]
    assert [%{run_id: "run-b"}] = result["run-b"]
  end

  test "a run without worktrees maps to [] and unrequested runs are absent" do
    assert :ok = ProjectionStore.apply_events([created("run-a", "phase-a")])

    result = ProjectionStore.worktrees_for_runs(["run-a", "run-missing"])

    assert result["run-missing"] == []
    assert [%{run_id: "run-a"}] = result["run-a"]
    assert ProjectionStore.worktrees_for_runs(["run-missing"]) == %{"run-missing" => []}
    refute Map.has_key?(ProjectionStore.worktrees_for_runs(["run-missing"]), "run-a")
  end

  test "an empty list returns an empty map" do
    assert :ok = ProjectionStore.apply_events([created("run-a", "phase-a")])
    assert ProjectionStore.worktrees_for_runs([]) == %{}
  end
end
