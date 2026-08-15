defmodule ForemanServer.Events.WorkSubmitted do
  @moduledoc "Typed event emitted when a work request is submitted."
  @enforce_keys [:work_id, :project_id, :run_id, :submission_id, :workflow_snapshot]
  @type t :: %__MODULE__{
          work_id: String.t(),
          project_id: String.t(),
          run_id: String.t(),
          submission_id: String.t(),
          workflow_snapshot: map()
        }
  @derive Jason.Encoder
  defstruct [
    :work_id,
    :project_id,
    :run_id,
    :submission_id,
    :workflow_snapshot
  ]
end
