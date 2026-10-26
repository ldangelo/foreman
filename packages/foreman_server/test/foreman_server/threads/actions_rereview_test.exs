defmodule ForemanServer.Threads.ActionsRereviewTest do
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.TestSupport.UniqueIds
  alias ForemanServer.Threads.Actions

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp start_run!(run_id) do
    :ok =
      ProjectionStore.apply_events([
        %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p"}}
      ])
  end

  defp start_jobsite!(id) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "JobsiteStarted",
          payload: %{jobsite_id: id, repo_path: "/r", strategy: "head", project_id: "p"}
        }
      ])
  end

  defp record_met!(kind, id) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ReviewRecorded",
          payload: %{
            subject_kind: kind,
            subject_id: id,
            project_id: "p",
            verdict: "met",
            summary: "s",
            gap_bead_ids: [],
            at: "2026-01-01T00:00:00Z"
          }
        }
      ])
  end

  test "an unknown thread is thread_not_found" do
    assert {:error, :thread_not_found} = Actions.rereview("run:nope")
  end

  test "with no analyzer running a known run thread is analysis_disabled" do
    run_id = UniqueIds.unique_run_id("rereview")
    start_run!(run_id)

    assert {:error, :analysis_disabled} = Actions.rereview("run:" <> run_id)
  end

  describe "with an analyzer" do
    setup do
      start_supervised!({Task.Supervisor, name: ForemanServer.Review.TaskSupervisor})
      start_supervised!(ForemanServer.Review.Analyzer)
      :ok
    end

    test "a run thread maps to its run review" do
      run_id = UniqueIds.unique_run_id("rereview")
      start_run!(run_id)
      record_met!("run", run_id)

      assert {:error, {:not_rerunnable, "met"}} = Actions.rereview("run:" <> run_id)
    end

    test "a jobsite thread maps to its jobsite review" do
      id = "js-rereview-#{System.unique_integer([:positive])}"
      start_jobsite!(id)
      record_met!("jobsite", id)

      assert {:error, {:not_rerunnable, "met"}} = Actions.rereview("jobsite:" <> id)
    end

    test "a thread with no recorded review is not_reviewed" do
      run_id = UniqueIds.unique_run_id("rereview")
      start_run!(run_id)

      assert {:error, :not_reviewed} = Actions.rereview("run:" <> run_id)
    end
  end
end
