defmodule ForemanServer.Events.TaskExecutionFailed do
  @moduledoc "Typed event emitted when a task execution finishes with a failure."
  @enforce_keys [:task_id, :run_id, :reason]
  @type t :: %__MODULE__{
          task_id: String.t(),
          sequence: non_neg_integer() | nil,
          run_id: String.t(),
          reason: String.t()
        }
  @derive Jason.Encoder
  defstruct [:task_id, :sequence, :run_id, :reason]
end