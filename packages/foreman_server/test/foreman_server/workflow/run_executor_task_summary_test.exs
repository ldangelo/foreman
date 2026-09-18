defmodule ForemanServer.Workflow.RunExecutorTaskSummaryTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.RunExecutor

  describe "final AutoPR task summary context" do
    test "extracts task title, description, and safe identifiers from atom-keyed task state" do
      state = %{
        task: %{
          task_id: "task-1",
          title: "Task title",
          description: "Task description",
          external_id: "bead-1",
          external_link: "https://beads.example/bead-1",
          unexpected: "ignored"
        }
      }

      assert RunExecutor.__task_summary_context_for_test__(state) == %{
               task_title: "Task title",
               task_description: "Task description",
               task_id: "task-1",
               task_external_id: "bead-1",
               task_external_link: "https://beads.example/bead-1"
             }
    end

    test "extracts task summary from string-keyed task state" do
      state = %{
        task: %{
          "task_id" => "task-2",
          "title" => "String title",
          "description" => "String description",
          "external_id" => "bead-2",
          "external_link" => "https://beads.example/bead-2"
        }
      }

      assert RunExecutor.__task_summary_context_for_test__(state) == %{
               task_title: "String title",
               task_description: "String description",
               task_id: "task-2",
               task_external_id: "bead-2",
               task_external_link: "https://beads.example/bead-2"
             }
    end

    test "returns no task summary for ad-hoc state without task metadata" do
      assert RunExecutor.__task_summary_context_for_test__(%{task: %{workflow_name: "fix"}}) ==
               %{}

      assert RunExecutor.__task_summary_context_for_test__(%{task: %{}}) == %{}
      assert RunExecutor.__task_summary_context_for_test__(%{}) == %{}
    end

    test "does not synthesize from artifacts docs or git-like fields" do
      state = %{
        task: %{
          artifact_path: "docs/TRD/task.md",
          prompt: "pretend title",
          work_id: "work-1"
        }
      }

      assert RunExecutor.__task_summary_context_for_test__(state) == %{}
    end

    test "preserves malformed or partial values for AutoPR boundary validation" do
      assert RunExecutor.__task_summary_context_for_test__(%{task: %{title: "Only title"}}) == %{
               task_title: "Only title",
               task_description: nil
             }

      assert RunExecutor.__task_summary_context_for_test__(%{task: %{task_id: "task-only"}}) == %{
               task_title: nil,
               task_description: nil,
               task_id: "task-only"
             }

      assert RunExecutor.__task_summary_context_for_test__(%{
               task: %{title: "Title", description: nil, external_id: 42}
             }) == %{task_title: "Title", task_description: nil, task_external_id: 42}
    end
  end
end
