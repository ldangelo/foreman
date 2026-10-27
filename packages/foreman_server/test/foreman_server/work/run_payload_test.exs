defmodule ForemanServer.Work.RunPayloadTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Work.RunPayload

  describe "from_task_projection/1" do
    test "derives phase_specs from workflow_snapshot string key" do
      task_proj = %{
        run_id: "run-123",
        task_id: "task-456",
        project_id: "proj-789",
        approval_id: "approval-abc",
        workflow_snapshot: %{"phases" => [%{"id" => "phase-1"}]}
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

    test "derives phase_specs from workflow_snapshot atom key" do
      task_proj = %{
        run_id: "run-123",
        task_id: "task-456",
        project_id: "proj-789",
        approval_id: "approval-abc",
        workflow_snapshot: %{phases: [%{id: "phase-1", kind: "exec"}]}
      }

      result = RunPayload.from_task_projection(task_proj)

      assert result.phase_specs == [%{id: "phase-1", kind: "exec"}]
      assert result.source == :task
    end
  end

  describe "architecture — RunPayload is the sole constructor" do
    @moduledoc """
    Architecture invariant: no module outside `Work.RunPayload` may construct
    the RunPayload admission struct inline. All callers must go through
    `from_task_projection/1`.
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
