defmodule ForemanServer.Events.TaskExecutionCompleted do
  @moduledoc "Typed event emitted when a task execution finishes successfully."
  @enforce_keys [:task_id, :run_id]
  @type t :: %__MODULE__{
          task_id: String.t(),
          sequence: non_neg_integer() | nil,
          run_id: String.t()
        }
  @derive Jason.Encoder
  defstruct [:task_id, :sequence, :run_id]
end