defmodule ForemanServer.Workflow.RunExecutorAutoPRTaskMetadataTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Task
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor

  setup do
    ProjectionStoreReset.reset!()
    on_exit(fn -> ProjectionStoreReset.reset!() end)
    :ok
  end

  test "AutoPR context carries exact title and description from a projected TaskCreated event" do
    title = "AutoPR PR title/description: actual implementation"
    description = "Use the task description as the final PR body.\n\nKeep Markdown."

    assert {:ok, event_spec} =
             Task.handle_command(Task.initial_state(), %{
               type: "task.create",
               payload: %{
                 task_id: "task-autopr-metadata",
                 project_id: "project-autopr",
                 title: title,
                 description: description,
                 task_type: "implement",
                 workflow_type: "implement"
               }
             })

    assert :ok =
             ProjectionStore.apply_events([
               %{event_type: event_spec.event_type, payload: event_spec.payload}
             ])

    task = ProjectionStore.task_projection("task-autopr-metadata")

    context =
      RunExecutor.__auto_pr_context_for_test__(
        %{
          run_id: "run-autopr-metadata",
          task: task,
          source: :task,
          current_phase: nil,
          phase_specs: [],
          plan_context: %{"project_root" => "/tmp/foreman-autopr-metadata"},
          last_worktree: %{branch: "foreman/task-autopr-metadata/run-autopr-metadata"}
        },
        "main"
      )

    assert context.task_title == title
    assert context.task_description == description
    assert context.run_id == "run-autopr-metadata"
    assert context.base_branch == "main"
    assert context.head_branch == "foreman/task-autopr-metadata/run-autopr-metadata"
    assert context.cwd == "/tmp/foreman-autopr-metadata"
  end

  test "task-backed context preserves malformed metadata for AutoPR validation instead of omitting it" do
    context =
      RunExecutor.__auto_pr_context_for_test__(
        %{
          run_id: "run-autopr-bad-metadata",
          task: %{
            task_id: "task-autopr-bad-metadata",
            title: "Good title",
            description: nil
          },
          source: :task,
          current_phase: nil,
          phase_specs: [],
          plan_context: %{"project_root" => "/tmp/foreman-autopr-bad-metadata"},
          last_worktree: %{branch: "foreman/task-autopr-bad-metadata/run-autopr-bad-metadata"}
        },
        "main"
      )

    assert Map.has_key?(context, :task_title)
    assert Map.has_key?(context, :task_description)
    assert context.task_title == "Good title"
    assert context.task_description == nil
  end

  test "non-task runs keep legacy AutoPR context without task metadata" do
    context =
      RunExecutor.__auto_pr_context_for_test__(
        %{
          run_id: "run-no-task",
          task: %{},
          source: :work_request,
          current_phase: nil,
          phase_specs: [],
          plan_context: %{"project_root" => "/tmp/foreman-autopr-no-task"},
          last_worktree: %{branch: "foreman/run-no-task"}
        },
        "main"
      )

    refute Map.has_key?(context, :task_title)
    refute Map.has_key?(context, :task_description)
  end
end
