defmodule ForemanServer.Coordinator.DispatchTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Coordinator.Dispatch

  defmodule Gateway do
    @moduledoc false
    def dispatch_system(command) do
      send(self(), {:dispatched, command})
      {:ok, nil}
    end

    def dispatch_operator(command) do
      send(self(), {:dispatched_operator, command})
      {:ok, nil}
    end

    def dispatch_system_approval(command) do
      send(self(), {:dispatched_approval, command})
      {:ok, nil}
    end
  end

  defp update(payload),
    do: %{type: "project.update", command_id: "c-1", aggregate_id: "project:p", payload: payload}

  test "a project.update that sets required_checks is refused and nothing is dispatched" do
    for payload <- [
          %{project_id: "p", required_checks: []},
          %{project_id: "p", required_checks: [%{"name" => "ci", "kind" => "check_run"}]},
          %{project_id: "p", config: %{required_checks: []}}
        ] do
      assert {:error, {:forbidden_setting, :required_checks}} =
               Dispatch.system(Gateway, update(payload))
    end

    refute_received {:dispatched, _}
  end

  test "a project.update that clears required_checks is refused and nothing is dispatched" do
    for cleared <- [["required_checks"], [:required_checks]] do
      assert {:error, {:forbidden_setting, :required_checks}} =
               Dispatch.system(Gateway, update(%{project_id: "p", cleared_settings: cleared}))
    end

    refute_received {:dispatched, _}
  end

  test "a project.update of another setting is dispatched as before" do
    command = update(%{project_id: "p", goal: "g", cleared_settings: ["instructions"]})
    assert {:ok, nil} = Dispatch.system(Gateway, command)
    assert_received {:dispatched, ^command}
  end

  test "another command type naming required_checks in its payload is not touched by the setting guard" do
    command = %{type: "task.create", payload: %{required_checks: []}}
    assert {:ok, nil} = Dispatch.system(Gateway, command)
    assert_received {:dispatched, ^command}
  end
end
