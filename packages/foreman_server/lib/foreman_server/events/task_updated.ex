defmodule ForemanServer.Events.TaskUpdated do
  @enforce_keys [:task_id]
  @type t :: %__MODULE__{
    task_id: String.t(),
    status: String.t() | nil
  }
  @derive Jason.Encoder
  defstruct [:task_id, :status]
end
