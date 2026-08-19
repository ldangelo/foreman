defmodule ForemanServer.Workflow.StepIdempotencyTest do
  use ExUnit.Case, async: true
  test "key_for builds expected format" do
    assert "create-task-1-create_prd" = ForemanServer.Workflow.StepIdempotency.key_for("task-1", :create_prd)
  end
  test "all_keys_for maps step names to keys" do
    keys = ForemanServer.Workflow.StepIdempotency.all_keys_for("t1", [{:a, "skill-a"}, {:b, "skill-b"}])
    assert [{"a", "create-t1-a"}, {"b", "create-t1-b"}] = keys
  end
end
