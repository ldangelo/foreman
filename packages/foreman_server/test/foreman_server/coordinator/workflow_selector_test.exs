defmodule ForemanServer.Coordinator.WorkflowSelectorTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Coordinator.WorkflowSelector

  @invalid [%{name: "lvclaude", reason: "models.default must be bare"}]

  test "an installed workflow is selected" do
    assert {:ok, "fix"} = WorkflowSelector.select(%{"workflow" => "fix"}, ["fix"], @invalid)
  end

  test "a name that is installed but refused reports the refusal, not 'unknown'" do
    assert {:error, {:invalid_workflow, "lvclaude", "models.default must be bare"}} =
             WorkflowSelector.select(%{"workflow" => "lvclaude"}, ["fix"], @invalid)
  end

  test "a name that is neither installed nor refused is unknown, with the sorted valid list" do
    assert {:error, {:unknown_workflow, "hotfix", ["a", "fix"]}} =
             WorkflowSelector.select(%{"workflow" => "hotfix"}, ["fix", "a"], @invalid)
  end

  test "a workflow still served from its previous version stays selectable" do
    assert {:ok, "lvclaude"} =
             WorkflowSelector.select(%{"workflow" => "lvclaude"}, ["lvclaude"], @invalid)
  end

  test "no workflow and no task_type is :no_workflow" do
    assert {:error, :no_workflow} = WorkflowSelector.select(%{}, ["fix"], @invalid)
  end
end
