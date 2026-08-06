defmodule ForemanServer.TaskProviderTest do
  use ExUnit.Case, async: true

  test "declares 11 callbacks via @behaviour" do
    assert function_exported?(ForemanServer.TaskProvider, :behaviour_info, 1) == true
  end

  test "behaviour_info(:callbacks) returns 11 expected callbacks" do
    callbacks = ForemanServer.TaskProvider.behaviour_info(:callbacks)

    assert Keyword.keyword?(callbacks)
    assert length(callbacks) == 11
    assert {:name, 0} in callbacks
    assert {:capabilities, 0} in callbacks
    assert {:available?, 0} in callbacks
    assert {:list_ready, 2} in callbacks
    assert {:get, 2} in callbacks
    assert {:claim, 3} in callbacks
    assert {:complete, 3} in callbacks
    assert {:fail, 3} in callbacks
    assert {:reopen, 3} in callbacks
    assert {:set_priority, 3} in callbacks
    assert {:add_dependency, 3} in callbacks
    assert length(callbacks) == 11
  end
end
