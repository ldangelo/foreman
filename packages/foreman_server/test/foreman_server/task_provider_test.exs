defmodule ForemanServer.TaskProviderTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TaskProvider.Comment

  test "exposes callback reflection for provider contract tests" do
    assert is_list(ForemanServer.TaskProvider.behaviour_info(:callbacks))
  end

  test "behaviour_info(:callbacks) returns 13 expected callbacks" do
    callbacks = ForemanServer.TaskProvider.behaviour_info(:callbacks)

    assert Keyword.keyword?(callbacks)
    assert length(callbacks) == 13
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
    assert {:comment, 3} in callbacks
    assert {:create, 2} in callbacks
    assert length(callbacks) == 13
  end

  test "comment result is a typed struct with enforced keys" do
    assert_raise ArgumentError, fn -> struct!(Comment, %{status: "comment_added"}) end

    assert %Comment{provider_issue_id: "task-1", status: "comment_added"} =
             struct!(Comment, %{provider_issue_id: "task-1", status: "comment_added"})
  end
end
