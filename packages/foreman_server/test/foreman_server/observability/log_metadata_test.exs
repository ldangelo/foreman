defmodule ForemanServer.Observability.LogMetadataTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Observability.LogMetadata

  test "builds canonical metadata from complete run and phase context" do
    metadata =
      LogMetadata.build(
        %{
          run_id: "run-1",
          task_id: "task-1",
          project_id: "project-1",
          workflow_name: "implement",
          worker_id: "worker-1"
        },
        phase: %{index: 2, name: "quality", type: "command"},
        trace_context: %{trace_id: "trace-1", span_id: "span-1"}
      )

    assert metadata.run_id == "run-1"
    assert metadata.task_id == "task-1"
    assert metadata.phase_index == 2
    assert metadata.phase_name == "quality"
    assert metadata.worker_id == "worker-1"
    assert metadata.trace_id == "trace-1"
    assert metadata.span_id == "span-1"
  end

  test "omits absent fields instead of guessing" do
    metadata = LogMetadata.build(%{run_id: "run-2"})

    assert metadata == %{run_id: "run-2"}
    refute Map.has_key?(metadata, :task_id)
    refute Map.has_key?(metadata, :phase_index)
  end
end
