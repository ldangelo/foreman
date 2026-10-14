defmodule ForemanServer.Work.RunPayload do
  @moduledoc """
  Canonical admission payload for a run, built from a task_projection.
  """

  @type t :: %__MODULE__{
          run_id: String.t(),
          task_id: String.t() | nil,
          project_id: String.t(),
          approval_id: String.t() | nil,
          workflow_snapshot: map(),
          phase_specs: [map()],
          source: :task
        }

  defstruct [
    :run_id,
    :task_id,
    :project_id,
    :approval_id,
    :workflow_snapshot,
    :phase_specs,
    :source
  ]

  @spec from_task_projection(map()) :: t()
  def from_task_projection(%{
        run_id: run_id,
        task_id: task_id,
        project_id: project_id,
        approval_id: approval_id,
        workflow_snapshot: workflow_snapshot
      }) do
    phase_specs =
      Map.get(workflow_snapshot, "phases", []) ++ Map.get(workflow_snapshot, :phases, [])

    %__MODULE__{
      run_id: run_id,
      task_id: task_id,
      project_id: project_id,
      approval_id: approval_id,
      workflow_snapshot: workflow_snapshot,
      phase_specs: phase_specs,
      source: :task
    }
  end
end
