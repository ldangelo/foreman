defmodule ForemanServer.Events.TaskApproved do
  @moduledoc "Typed event emitted when a task is approved for execution."
  @enforce_keys [:task_id, :approval_id, :approved_by, :approved_at, :run_id, :workflow_snapshot]
  @type t :: %__MODULE__{
          task_id: String.t(),
          sequence: non_neg_integer() | nil,
          approval_id: String.t(),
          approved_by: String.t(),
          approved_at: String.t(),
          run_id: String.t(),
          workflow_snapshot: map()
        }
  @derive Jason.Encoder
  defstruct [
    :task_id,
    :sequence,
    :approval_id,
    :approved_by,
    :approved_at,
    :run_id,
    :workflow_snapshot
  ]
end
