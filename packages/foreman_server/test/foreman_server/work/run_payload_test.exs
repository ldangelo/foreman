defmodule ForemanServer.Work.RunPayloadTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Work.RunPayload

  describe "from_task_projection/1" do
    test "returns correct struct with all 7 keys" do
      task_proj = %{
        run_id: "run-123",
        task_id: "task-456",
        project_id: "proj-789",
        approval_id: "approval-abc",
        workflow_snapshot: %{"phases" => [%{"id" => "phase-1"}]},
        phase_specs: [%{"id" => "phase-1"}]
      }

      result = RunPayload.from_task_projection(task_proj)

      assert result.run_id == "run-123"
      assert result.task_id == "task-456"
      assert result.project_id == "proj-789"
      assert result.approval_id == "approval-abc"
      assert result.workflow_snapshot == %{"phases" => [%{"id" => "phase-1"}]}
      assert result.phase_specs == [%{"id" => "phase-1"}]
      assert result.source == :task
    end
  end

  describe "from_work_projection/1" do
    test "returns correct struct with all 7 keys" do
      work_proj = %{
        run_id: "run-123",
        work_id: "work-456",
        project_id: "proj-789",
        submission_id: "sub-abc",
        workflow_snapshot: %{"phases" => [%{"id" => "phase-1"}]}
      }

      result = RunPayload.from_work_projection(work_proj)

      assert result.run_id == "run-123"
      assert result.task_id == nil
      assert result.project_id == "proj-789"
      assert result.approval_id == nil
      assert result.workflow_snapshot == %{"phases" => [%{"id" => "phase-1"}]}
      assert result.phase_specs == [%{"id" => "phase-1"}]
      assert result.source == :work
    end

    test "extracts phase_specs from workflow_snapshot phases key" do
      work_proj = %{
        run_id: "run-123",
        work_id: "work-456",
        project_id: "proj-789",
        submission_id: "sub-abc",
        workflow_snapshot: %{"phases" => [%{"id" => "phase-1"}]}
      }

      result = RunPayload.from_work_projection(work_proj)

      assert result.phase_specs == [%{"id" => "phase-1"}]
    end
  end

  describe "key parity" do
    test "both constructors return identical key sets" do
      task_proj = %{
        run_id: "run-123",
        task_id: "task-456",
        project_id: "proj-789",
        approval_id: "approval-abc",
        workflow_snapshot: %{"phases" => [%{"id" => "phase-1"}]},
        phase_specs: [%{"id" => "phase-1"}]
      }

      work_proj = %{
        run_id: "run-123",
        work_id: "work-456",
        project_id: "proj-789",
        submission_id: "sub-abc",
        workflow_snapshot: %{"phases" => [%{"id" => "phase-1"}]}
      }

      task_result = RunPayload.from_task_projection(task_proj)
      work_result = RunPayload.from_work_projection(work_proj)

      assert Map.keys(task_result) == Map.keys(work_result)
    end
  end

  describe "source field" do
    test "source is :task for from_task_projection" do
      task_proj = %{
        run_id: "run-123",
        task_id: "task-456",
        project_id: "proj-789",
        approval_id: "approval-abc",
        workflow_snapshot: %{},
        phase_specs: []
      }

      result = RunPayload.from_task_projection(task_proj)
      assert result.source == :task
    end

    test "source is :work for from_work_projection" do
      work_proj = %{
        run_id: "run-123",
        work_id: "work-456",
        project_id: "proj-789",
        submission_id: "sub-abc",
        workflow_snapshot: %{}
      }

      result = RunPayload.from_work_projection(work_proj)
      assert result.source == :work
    end
  end
end
