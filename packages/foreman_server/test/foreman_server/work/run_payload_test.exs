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

  # ---------------------------------------------------------------------------
  # TRD-026-TEST: Payload parity + architecture invariant
  # ---------------------------------------------------------------------------

  describe "TRD-026-TEST: payload parity" do
    test "value types are compatible: task path returns string task_id, work path returns nil" do
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

      # Both have identical key set
      assert Map.keys(task_result) == Map.keys(work_result)

      # task_id is String in task path, nil in work path
      assert is_binary(task_result.task_id)
      assert is_nil(work_result.task_id)

      # approval_id is String in task path, nil in work path
      assert is_binary(task_result.approval_id)
      assert is_nil(work_result.approval_id)

      # source is atom :task vs :work
      assert task_result.source == :task
      assert work_result.source == :work
    end
  end

  describe "TRD-026-TEST: architecture — RunPayload is the sole constructor" do
    @moduledoc """
    Architecture invariant: no module outside `Work.RunPayload` may construct
    the RunPayload admission struct inline. All callers must go through
    `from_task_projection/1` or `from_work_projection/1`.
    """

    test "no module outside Work.RunPayload constructs %RunPayload{} inline" do
      files =
        Path.wildcard("lib/foreman_server/**/*.ex")
        |> Enum.reject(fn f ->
          String.contains?(f, "_build/") ||
            String.ends_with?(f, "work/run_payload.ex")
        end)

      offenders =
        Enum.flat_map(files, fn file ->
          source = File.read!(file)

          source
          |> String.split("\n")
          |> Enum.with_index(1)
          |> Enum.flat_map(fn {line, line_no} ->
            if line =~ ~r/%RunPayload\s*\{/ ||
                 line =~ ~r/%ForemanServer\.Work\.RunPayload\s*\{/ do
              [{file, line_no}]
            else
              []
            end
          end)
        end)

      assert offenders == [],
             "Unexpected %RunPayload{} constructions outside Work.RunPayload:\n" <>
               Enum.map_join(offenders, "\n", fn {f, l} -> "  - #{f}:#{l}" end)
    end
  end
end
