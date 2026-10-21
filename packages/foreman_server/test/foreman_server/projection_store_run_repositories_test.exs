defmodule ForemanServer.ProjectionStoreRunRepositoriesTest do
  @moduledoc """
  `ProjectionStore.run_repositories/1`: the per-repository join of one run.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp wt(op, run_id, extra) do
    %{
      event_type: "WorktreeCreated",
      payload:
        Map.merge(
          %{
            operation_id: op,
            project_id: "p",
            run_id: run_id,
            phase_id: "ph",
            worktree_path: "/w/#{op}",
            repo_path: "/r/#{op}"
          },
          extra
        )
    }
  end

  test "unknown run with no events reads []" do
    assert [] = ProjectionStore.run_repositories("run-none")
  end

  test "single-repo run: one primary entry with string repo_id \"main\" and run-level PR data" do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{run_id: "run-1", project_id: "p", workflow_snapshot: %{}}
               },
               %{
                 event_type: "RunBaseBranchRecorded",
                 payload: %{run_id: "run-1", base_branch: "dev"}
               },
               wt("wt-run-1", "run-1", %{}),
               %{
                 event_type: "PrAssociated",
                 payload: %{run_id: "run-1", pr_url: "https://x/pull/1"}
               }
             ])

    assert [
             %{
               repo_id: "main",
               primary?: true,
               worktree: %{operation_id: "wt-run-1", worktree_path: "/w/wt-run-1"},
               base_branch: "dev",
               pr_association: %{pr_url: "https://x/pull/1"},
               gate: :none
             }
           ] = ProjectionStore.run_repositories("run-1")
  end

  test "multi-repo run: primary first even when a secondary sorts earlier; secondaries by repo_id" do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: "run-2",
                   project_id: "p",
                   workflow_snapshot: %{},
                   repo_ids: ["web", "api"]
                 }
               },
               %{
                 event_type: "RunBaseBranchRecorded",
                 payload: %{run_id: "run-2", base_branch: "main-b"}
               },
               %{
                 event_type: "RunBaseBranchRecorded",
                 payload: %{run_id: "run-2", repo_id: "api", base_branch: "api-b"}
               },
               wt("zz-primary", "run-2", %{}),
               wt("aa-web", "run-2", %{repo_id: "web"}),
               wt("bb-api", "run-2", %{repo_id: "api"})
             ])

    assert [
             %{repo_id: "main", primary?: true, worktree: %{operation_id: "zz-primary"}},
             %{
               repo_id: "api",
               primary?: false,
               worktree: %{operation_id: "bb-api"},
               base_branch: "api-b",
               pr_association: nil,
               gate: nil,
               pr_state: nil
             },
             %{repo_id: "web", primary?: false, worktree: %{operation_id: "aa-web"}}
           ] = ProjectionStore.run_repositories("run-2")
  end

  test "a repo planned in repo_ids with no worktree yet still appears, worktree nil" do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: "run-3",
                   project_id: "p",
                   workflow_snapshot: %{},
                   repo_ids: ["api"]
                 }
               }
             ])

    assert [%{repo_id: "main", worktree: nil}, %{repo_id: "api", worktree: nil}] =
             ProjectionStore.run_repositories("run-3")
  end

  test "a run whose selected primary is a non-default repo reports that id as primary" do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{
                   run_id: "run-4",
                   project_id: "p",
                   workflow_snapshot: %{},
                   repo_id: "api"
                 }
               },
               wt("wt-run-4", "run-4", %{})
             ])

    assert [%{repo_id: "api", primary?: true, worktree: %{operation_id: "wt-run-4"}}] =
             ProjectionStore.run_repositories("run-4")
  end

  test "a repo with several phase worktrees reports the still-created one" do
    assert :ok =
             ProjectionStore.apply_events([
               %{
                 event_type: "RunStarted",
                 payload: %{run_id: "run-5", project_id: "p", workflow_snapshot: %{}}
               },
               wt("wt-a", "run-5", %{}),
               wt("wt-b", "run-5", %{}),
               %{
                 event_type: "WorktreeCleaned",
                 payload: %{
                   operation_id: "wt-b",
                   project_id: "p",
                   run_id: "run-5",
                   phase_id: "ph"
                 }
               }
             ])

    assert [%{worktree: %{operation_id: "wt-a", status: "created"}}] =
             ProjectionStore.run_repositories("run-5")
  end
end
