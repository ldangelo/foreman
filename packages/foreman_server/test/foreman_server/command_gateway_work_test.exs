defmodule ForemanServer.CommandGatewayWorkTest do
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway

  setup do
    # Reset projection store before each test
    :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
      %{
        state
        | projects: %{},
          runs: %{},
          tasks: %{},
          phases: %{},
          worktrees: %{},
          worktree_create_orphans: %{}
      }
    end)

    :ok
  end

  describe "work.submit operator type" do
    test "work.submit is in allowed_operator_types" do
      # A missing aggregate_id returns missing_aggregate_id error,
      # NOT command_not_allowed, proving work.submit is an allowed type
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-work-submit-type-check",
                 type: "work.submit",
                 payload: %{
                   work_id: "work-abc",
                   project_id: "proj-xyz",
                   prompt: "test prompt",
                   workflow_snapshot: %{}
                 }
               })
    end
  end

  describe "work.cancel operator type" do
    test "work.cancel is in allowed_operator_types" do
      # A missing aggregate_id returns missing_aggregate_id error,
      # NOT command_not_allowed, proving work.cancel is an allowed type
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-work-cancel-type-check",
                 type: "work.cancel",
                 payload: %{
                   work_id: "work-abc"
                 }
               })
    end
  end

  describe "work.submit validation" do
    test "rejects missing work_id" do
      assert {:error, {:invalid_envelope, :missing_work_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-ws-1",
                 aggregate_id: "work:abc",
                 type: "work.submit",
                 payload: %{
                   project_id: "proj-xyz",
                   prompt: "test",
                   workflow_snapshot: %{}
                 }
               })
    end

    test "rejects empty work_id" do
      assert {:error, {:invalid_envelope, :missing_work_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-ws-2",
                 aggregate_id: "work:abc",
                 type: "work.submit",
                 payload: %{
                   work_id: "",
                   project_id: "proj-xyz",
                   prompt: "test",
                   workflow_snapshot: %{}
                 }
               })
    end

    test "rejects non-binary work_id" do
      assert {:error, {:invalid_envelope, :missing_work_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-ws-3",
                 aggregate_id: "work:abc",
                 type: "work.submit",
                 payload: %{
                   work_id: 123,
                   project_id: "proj-xyz",
                   prompt: "test",
                   workflow_snapshot: %{}
                 }
               })
    end

    test "rejects mismatched aggregate_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-ws-4",
                 aggregate_id: "work:wrong",
                 type: "work.submit",
                 payload: %{
                   work_id: "abc",
                   project_id: "proj-xyz",
                   prompt: "test",
                   workflow_snapshot: %{}
                 }
               })
    end

    test "rejects missing aggregate_id" do
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-ws-5",
                 type: "work.submit",
                 payload: %{
                   work_id: "abc",
                   project_id: "proj-xyz",
                   prompt: "test",
                   workflow_snapshot: %{}
                 }
               })
    end

    test "rejects missing project_id" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-ws-6",
                 aggregate_id: "work:abc",
                 type: "work.submit",
                 payload: %{
                   work_id: "abc",
                   prompt: "test",
                   workflow_snapshot: %{}
                 }
               })
    end

    test "rejects non-existent project" do
      assert {:error, {:project_not_found, "proj-nonexistent"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-ws-7",
                 aggregate_id: "work:abc",
                 type: "work.submit",
                 payload: %{
                   work_id: "abc",
                   project_id: "proj-nonexistent",
                   prompt: "test",
                   workflow_snapshot: %{}
                 }
               })
    end

    test "rejects archived project" do
      # Set up an archived project
      :sys.replace_state(ForemanServer.ProjectionStore, fn state ->
        put_in(state.projects["proj-archived"], %{
          project_id: "proj-archived",
          archived?: true
        })
      end)

      assert {:error, {:project_archived, "proj-archived"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-ws-8",
                 aggregate_id: "work:abc",
                 type: "work.submit",
                 payload: %{
                   work_id: "abc",
                   project_id: "proj-archived",
                   prompt: "test",
                   workflow_snapshot: %{}
                 }
               })
    end
  end

  describe "work.cancel validation" do
    test "rejects missing work_id" do
      assert {:error, {:invalid_envelope, :missing_work_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-wc-1",
                 aggregate_id: "work:abc",
                 type: "work.cancel",
                 payload: %{}
               })
    end

    test "rejects empty work_id" do
      assert {:error, {:invalid_envelope, :missing_work_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-wc-2",
                 aggregate_id: "work:abc",
                 type: "work.cancel",
                 payload: %{work_id: ""}
               })
    end

    test "rejects non-binary work_id" do
      assert {:error, {:invalid_envelope, :missing_work_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-wc-3",
                 aggregate_id: "work:abc",
                 type: "work.cancel",
                 payload: %{work_id: 123}
               })
    end

    test "rejects mismatched aggregate_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-wc-4",
                 aggregate_id: "work:wrong",
                 type: "work.cancel",
                 payload: %{work_id: "abc"}
               })
    end

    test "rejects missing aggregate_id" do
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-wc-5",
                 type: "work.cancel",
                 payload: %{work_id: "abc"}
               })
    end
  end
end
