defmodule ForemanServer.Commands.WorkSubmit do
  @moduledoc "Command to submit a new work request."

  @enforce_keys [:work_id, :project_id, :prompt, :workflow_snapshot]
  defstruct [
    :work_id,
    :project_id,
    :prompt,
    :workflow_snapshot,
    :submission_id,
    :run_id,
    :backend
  ]

  @type t :: %__MODULE__{
          work_id: String.t(),
          project_id: String.t(),
          prompt: String.t(),
          workflow_snapshot: map(),
          submission_id: String.t() | nil,
          run_id: String.t() | nil,
          backend: String.t() | nil
        }
end
