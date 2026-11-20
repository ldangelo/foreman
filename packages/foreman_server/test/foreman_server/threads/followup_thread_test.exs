defmodule ForemanServer.Threads.FollowUpThreadTest do
  # A follow-up run (a PR fix) has no task: its thread is its own run thread, named for the fix and
  # linked to the PR it works on.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Threads

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  test "a task-less follow-up run is a workflow thread titled for the fix" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: "run-fu", project_id: "pf"}},
        %{
          event_type: "RunFollowUpRequested",
          payload: %{
            run_id: "run-fu",
            project_id: "pf",
            kind: "pr_fix",
            requested_by: "pr_watcher",
            at: "2026-11-20T00:00:00Z",
            fix_kind: "ci",
            attach_branch: "feature/x",
            pr_url: "https://github.com/o/r/pull/7"
          }
        }
      ])

    assert {:ok, thread} = Threads.get("run:run-fu")
    assert thread.door == :workflow
    assert thread.task_id == nil
    assert thread.title == "PR fix (ci): feature/x"
    assert thread.pr_url == "https://github.com/o/r/pull/7"
  end

  test "an ordinary task-less run keeps its own title" do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: "run-plain", project_id: "pf"}}
      ])

    assert {:ok, thread} = Threads.get("run:run-plain")
    assert thread.title == "run-plain"
  end
end
