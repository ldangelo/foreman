defmodule ForemanServer.CommandGatewayTest do
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway

  describe "envelope validation" do
    test "rejects command without command_id" do
      assert {:error, {:invalid_envelope, :missing_command_id}} =
               CommandGateway.dispatch_operator(%{
                 aggregate_id: "task:abc",
                 type: "task.create",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects command without aggregate_id" do
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 type: "task.create",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects command without type" do
      assert {:error, {:invalid_envelope, :missing_type}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects non-allowed operator type" do
      assert {:error, {:command_not_allowed, "task.delete"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.delete",
                 payload: %{task_id: "abc"}
               })
    end
  end

  describe "aggregate_id contract" do
    test "project.register requires prefixed aggregate_id matching project_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "abc",
                 type: "project.register",
                 payload: %{project_id: "abc", path: "/tmp/p"}
               })
    end

    test "task.create requires task:<id> aggregate_id matching task_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.create",
                 payload: %{task_id: "abc", project_id: "p1"}
               })

      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "abc",
                 type: "task.create",
                 payload: %{task_id: "abc", project_id: "p1"}
               })
    end

    test "task.approve requires task:<id> aggregate_id matching task_id" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.approve",
                 payload: %{task_id: "abc", approved_by: "alice"}
               })
    end

    test "rejects numeric and non-binary entity IDs without crashing" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "project:123",
                 type: "project.register",
                 payload: %{project_id: 123, path: "/tmp/p"}
               })

      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.create",
                 payload: %{task_id: ["nested"], project_id: "p1"}
               })

      # aggregate_id itself must be a binary - non-binary aggregate_id is
      # caught at the envelope-shape layer (missing_aggregate_id).
      assert {:error, {:invalid_envelope, :missing_aggregate_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: :not_a_string,
                 type: "task.create",
                 payload: %{task_id: "abc", project_id: "p1"}
               })

      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.approve",
                 payload: %{task_id: nil, approved_by: "alice"}
               })
    end
  end

  describe "project.register validation" do
    test "rejects missing project_id" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "project:abc",
                 type: "project.register",
                 payload: %{path: "/tmp/p"}
               })
    end
  end

  describe "task.create validation" do
    test "rejects missing project_id when task_id present" do
      assert {:error, {:invalid_envelope, :missing_project_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.create",
                 payload: %{task_id: "abc"}
               })
    end
  end

  describe "task.approve validation" do
    test "rejects missing task_id" do

      assert {:error, {:invalid_envelope, :missing_task_id}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:abc",
                 type: "task.approve",
                 payload: %{}
               })
    end

    test "rejects mismatched aggregate_id" do

      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:wrong",
                 type: "task.approve",
                 payload: %{task_id: "abc"}
               })
    end

    test "rejects nonexistent task when payload is well-formed" do

      assert {:error, {:task_not_found, "missing-task"}} =
               CommandGateway.dispatch_operator(%{
                 command_id: "cid-1",
                 aggregate_id: "task:missing-task",
                 type: "task.approve",
                 payload: %{task_id: "missing-task"}
               })
    end
  end

  describe "dispatch_system" do
    test "bypasses operator whitelist (does not enforce allowed types)" do
      # dispatch_system routes through CommandRouter.dispatch/1 directly.
      # We send project.archive (NOT in the operator whitelist) against a
      # non-existent project. The test confirms dispatch_system does NOT
      # short-circuit with {:error, :command_not_allowed, _} - the
      # Aggregate handles the rejection itself with
      # {:error, :project_not_found}.
      result =
        CommandGateway.dispatch_system(%{
          command_id: "cid-1",
          aggregate_id: "project:does-not-exist",
          type: "project.archive",
          payload: %{project_id: "does-not-exist"}
        })

      assert match?({:error, _}, result)
      refute match?({:error, {:command_not_allowed, _}}, result)
    end
  end
end
