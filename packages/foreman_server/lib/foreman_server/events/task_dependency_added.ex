defmodule ForemanServer.Events.TaskDependencyAdded do
  @moduledoc "Typed event emitted when a task dependency is added."
  @enforce_keys [:task_id, :depends_on]
  @type t :: %__MODULE__{
          task_id: String.t(),
          sequence: non_neg_integer() | nil,
          depends_on: String.t()
        }
  @derive Jason.Encoder
  defstruct [:task_id, :sequence, :depends_on]
end
