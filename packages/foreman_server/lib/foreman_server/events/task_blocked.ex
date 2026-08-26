defmodule ForemanServer.Events.TaskBlocked do
  @moduledoc "Typed event emitted when a task is blocked, e.g. due to operator timeout."
  @enforce_keys [:task_id]
  @type t :: %__MODULE__{
          task_id: String.t(),
          sequence: non_neg_integer() | nil,
          reason: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:task_id, :sequence, reason: nil]
end
