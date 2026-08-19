defmodule ForemanServer.Workflow.ApproverAuthorizerTest do
  use ExUnit.Case, async: true
  test "authorized identity passes" do
    assert :ok = ForemanServer.Workflow.ApproverAuthorizer.authorize("github:ldangelo")
  end
  test "unauthorized identity rejected" do
    assert {:error, :unauthorized_approver} = ForemanServer.Workflow.ApproverAuthorizer.authorize("github:attacker")
  end
  test "custom allowlist" do
    assert :ok = ForemanServer.Workflow.ApproverAuthorizer.authorize("alice", ["alice", "bob"])
    assert {:error, :unauthorized_approver} = ForemanServer.Workflow.ApproverAuthorizer.authorize("carol", ["alice", "bob"])
  end
end
