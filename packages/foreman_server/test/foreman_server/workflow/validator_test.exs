defmodule ForemanServer.Workflow.ValidatorTest do
  use ExUnit.Case, async: true
  alias ForemanServer.Workflow.Validator
  test "valid workflow" do
    wf = %{id: "wf1", steps: [%{name: :a, skill: "create-prd"}]}
    assert :ok = Validator.validate(wf)
  end
  test "missing id" do
    assert {:error, :missing_id} = Validator.validate(%{steps: []})
  end
  test "unknown skill" do
    wf = %{id: "wf1", steps: [%{name: :a, skill: "bogus"}]}
    assert {:error, {:unknown_skill, "bogus"}} = Validator.validate(wf)
  end
end