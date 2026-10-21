defmodule ForemanServer.Aggregates.ProjectDefaultBranchTest do
  @moduledoc """
  `default_branch` was a project setting that nothing read: a run's base branch
  is the registered checkout's HEAD, latched per run. It is removed, commands
  carrying it fail with a distinct error, and historical events that still carry
  it must keep replaying.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Project

  defp registered_state do
    {:ok, event} =
      Project.handle_command(Project.initial_state(), %{
        type: "project.register",
        payload: %{project_id: "p-1", path: "/tmp/p-1"}
      })

    Project.apply_event(Project.initial_state(), event)
  end

  test "project.update carrying default_branch is rejected" do
    for key <- [:default_branch, "default_branch"] do
      assert {:error, {:setting_removed, :default_branch}} =
               Project.handle_command(registered_state(), %{
                 type: "project.update",
                 payload: %{:project_id => "p-1", key => "develop"}
               })
    end
  end

  test "project.register carrying default_branch is rejected" do
    assert {:error, {:setting_removed, :default_branch}} =
             Project.handle_command(Project.initial_state(), %{
               type: "project.register",
               payload: %{project_id: "p-1", path: "/tmp/p-1", default_branch: "develop"}
             })
  end

  test "a project.update without it still succeeds" do
    assert {:ok, %{event_type: "ProjectUpdated"}} =
             Project.handle_command(registered_state(), %{
               type: "project.update",
               payload: %{project_id: "p-1", name: "renamed"}
             })
  end

  test "legacy events carrying default_branch still fold, and later updates succeed" do
    state =
      Enum.reduce(
        [
          %{
            event_type: "ProjectRegistered",
            payload: %{
              "project_id" => "p-1",
              "path" => "/tmp/p-1",
              "default_branch" => "develop",
              "task_provider" => nil
            }
          },
          %{
            event_type: "ProjectUpdated",
            payload: %{"project_id" => "p-1", "default_branch" => "trunk", "task_provider" => nil}
          }
        ],
        Project.initial_state(),
        fn event, acc -> Project.apply_event(acc, event) end
      )

    assert state.exists?
    refute Map.has_key?(Map.from_struct(state), :default_branch)

    assert {:ok, %{event_type: "ProjectUpdated"}} =
             Project.handle_command(state, %{
               type: "project.update",
               payload: %{project_id: "p-1", name: "renamed"}
             })
  end
end
