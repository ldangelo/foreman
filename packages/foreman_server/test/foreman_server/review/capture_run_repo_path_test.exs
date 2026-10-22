defmodule ForemanServer.Review.CaptureRunRepoPathTest do
  @moduledoc """
  `Capture.run_repo_path/1` returns the PRIMARY repository's path in a multi-repo run.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Capture
  alias ForemanServer.TestSupport.ProjectionStoreReset

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp wt(op, extra) do
    %{
      event_type: "WorktreeCreated",
      payload:
        Map.merge(
          %{
            operation_id: op,
            project_id: "p",
            run_id: "run-m",
            phase_id: "ph",
            worktree_path: "/w/#{op}",
            repo_path: "/repos/#{op}"
          },
          extra
        )
    }
  end

  test "primary wins even when a secondary worktree sorts first" do
    assert :ok =
             ProjectionStore.apply_events([
               wt("aa-secondary", %{repo_id: "api"}),
               wt("zz-primary", %{})
             ])

    assert {:ok, "/repos/zz-primary"} = Capture.run_repo_path("run-m")
  end

  test "a secondary-only run (no primary worktree) is a typed error, never a guess" do
    assert :ok = ProjectionStore.apply_events([wt("aa-secondary", %{repo_id: "api"})])

    assert {:error, %{code: :archive_missing}} = Capture.run_repo_path("run-m")
  end
end
