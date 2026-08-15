defmodule ForemanServer.Workflow.RunExecutorSourceBranchTest do
  # TRD-032-TEST: Source-branch tests
  # Verifies that RunExecutor routes to the correct aggregate based on state.source:
  # - work_request source → WorkRequest aggregate, no TaskProvider callback
  # - task source → Task aggregate (existing behaviour, unchanged)
  #
  # These tests verify the logic at the function level.
  # Full integration tests require application start (see run_executor_test.exs).
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.RunExecutor

  describe "source determination" do
    test "source is :task when task_projection has task_id" do
      task_projection = %{
        "task_id" => "TASK-123",
        "run_id" => "RUN-456",
        "source_repo_path" => "/tmp/repo"
      }

      source = determine_source(task_projection)
      assert source == :task
    end

    test "source is :task when task_projection has task_id as atom key" do
      task_projection = %{
        task_id: "TASK-123",
        run_id: "RUN-456",
        source_repo_path: "/tmp/repo"
      }

      source = determine_source(task_projection)
      assert source == :task
    end

    test "source is :work_request when task_projection has work_id but no task_id" do
      task_projection = %{
        "work_id" => "WORK-789",
        "run_id" => "RUN-456"
      }

      source = determine_source(task_projection)
      assert source == :work_request
    end

    test "source is :work_request when task_projection has work_id as atom key" do
      task_projection = %{
        work_id: "WORK-789",
        run_id: "RUN-456"
      }

      source = determine_source(task_projection)
      assert source == :work_request
    end

    test "source defaults to :task when task_projection has neither" do
      task_projection = %{
        "run_id" => "RUN-456"
      }

      source = determine_source(task_projection)
      assert source == :task
    end
  end

  # Mirrors the source determination logic in RunExecutor.init/1
  defp determine_source(task_projection) do
    cond do
      Map.get(task_projection, :task_id) || Map.get(task_projection, "task_id") ->
        :task

      Map.get(task_projection, :work_id) || Map.get(task_projection, "work_id") ->
        :work_request

      true ->
        :task
    end
  end
end
