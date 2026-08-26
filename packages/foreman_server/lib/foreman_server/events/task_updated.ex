defmodule ForemanServer.Events.TaskUpdated do
  @moduledoc "Typed event emitted when a task's mutable fields change (non-approval transitions)."
  @enforce_keys [:task_id]
  @type t :: %__MODULE__{
          task_id: String.t(),
          sequence: non_neg_integer() | nil,
          status: String.t() | nil,
          priority: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:task_id, :sequence, :status, :priority, :title, :description]
end
