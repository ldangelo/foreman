defmodule ForemanServer.RepoIdReplayTest do
  @moduledoc """
  E12 replay safety: `repo_id`/`repo_ids` are declared on the strictly decoded
  events, legacy streams (no such keys) still decode and mean "primary", and
  `Run` ignores event types it does not know.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Run
  alias ForemanServer.EventCodec
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.Worktree

  @correlation %{operation_id: "wt-run-1", project_id: "p", run_id: "run-1", phase_id: "ph"}

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  describe "strict decode" do
    test "legacy payloads (no repo keys) decode with nil repo fields" do
      cases = [
        {"WorktreeCreated", @correlation},
        {"WorktreeCleaned", @correlation},
        {"WorktreeCreateOrphanRecorded", Map.put(@correlation, :worktree_path, "/w")},
        {"WorktreeCreateOrphanResolved", @correlation},
        {"PrAssociated", %{run_id: "run-1", pr_url: "https://x/pull/1"}},
        {"TaskCreated",
         %{task_id: "t", project_id: "p", title: "T", status: "open", task_type: "task"}},
        {"RunStarted", %{run_id: "run-1", project_id: "p"}}
      ]

      for {type, payload} <- cases do
        decoded = EventCodec.decode!(type, payload)
        assert decoded.repo_id == nil, type
        if Map.has_key?(decoded, :repo_ids), do: assert(decoded.repo_ids == nil, type)
      end
    end

    test "payloads carrying repo_id/repo_ids decode (string keys as persisted)" do
      assert %{repo_id: "b"} =
               EventCodec.decode!(
                 "WorktreeCreated",
                 stringify(Map.put(@correlation, :repo_id, "b"))
               )

      assert %{repo_id: "b", repo_ids: ["c"]} =
               EventCodec.decode!(
                 "RunStarted",
                 stringify(%{run_id: "run-1", project_id: "p", repo_id: "b", repo_ids: ["c"]})
               )

      assert %{repo_id: "b"} =
               EventCodec.decode!(
                 "PrAssociated",
                 stringify(%{run_id: "r", pr_url: "u", repo_id: "b"})
               )
    end

    test "an undeclared key is still rejected" do
      assert_raise ArgumentError, ~r/unknown fields/, fn ->
        EventCodec.decode!("WorktreeCreated", Map.put(@correlation, :repo_ident, "b"))
      end
    end

    defp stringify(map), do: Map.new(map, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  describe "Worktree.operation_id/2" do
    test "primary keeps wt-<run_id>; secondary appends the repo id" do
      assert Worktree.operation_id("run-1", nil) == "wt-run-1"
      assert Worktree.operation_id("run-1", "api") == "wt-run-1-api"
      refute Worktree.operation_id("run-1", "api") == Worktree.operation_id("run-1", nil)
    end
  end

  describe "worktree projection" do
    test "legacy WorktreeCreated (no repo_id) is primary; with repo_id it is not" do
      assert :ok =
               ProjectionStore.apply_events([
                 %{event_type: "WorktreeCreated", payload: @correlation},
                 %{
                   event_type: "WorktreeCreated",
                   payload:
                     Map.merge(@correlation, %{operation_id: "wt-run-1-api", repo_id: "api"})
                 }
               ])

      assert %{repo_id: nil, primary?: true} = ProjectionStore.worktree("wt-run-1")
      assert %{repo_id: "api", primary?: false} = ProjectionStore.worktree("wt-run-1-api")

      assert :ok =
               ProjectionStore.apply_events([
                 %{
                   event_type: "WorktreeCleaned",
                   payload:
                     Map.merge(@correlation, %{operation_id: "wt-run-1-api", repo_id: "api"})
                 }
               ])

      assert %{status: "cleaned", repo_id: "api", primary?: false} =
               ProjectionStore.worktree("wt-run-1-api")
    end
  end

  describe "Run.apply_event/2" do
    test "an unknown event type leaves the state unchanged" do
      state = Run.initial_state()

      # An event type a future build may add: replay on this build must skip it. (Not
      # `RunRepoPrFailed`: since E12-S6 the Run aggregate folds that one.)
      assert Run.apply_event(state, %{
               event_type: "RunEventFromAFutureBuild",
               payload: %{run_id: "r"}
             }) == state
    end
  end
end
