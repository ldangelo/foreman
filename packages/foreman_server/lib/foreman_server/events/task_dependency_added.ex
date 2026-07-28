defmodule ForemanServer.Events.TaskDependencyAdded do
  @enforce_keys [:task_id, :depends_on]
  @type t :: %__MODULE__{
    task_id: String.t(),
    depends_on: String.t()
  }
  @derive Jason.Encoder
  defstruct [:task_id, :depends_on]
end
