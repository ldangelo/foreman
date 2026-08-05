defmodule ForemanServer.Events.TaskDispatched do
  @moduledoc "Typed event emitted when a task claim has been confirmed."
  @enforce_keys [:task_id, :run_id, :approval_id]
  @type t :: %__MODULE__{
          task_id: String.t(),
          sequence: non_neg_integer() | nil,
          run_id: String.t(),
          approval_id: String.t()
        }
  @derive Jason.Encoder
  defstruct [:task_id, :sequence, :run_id, :approval_id]
end