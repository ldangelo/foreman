defmodule ForemanServer.Events.RunStarted do
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{
    run_id: String.t(),
    task_id: String.t() | nil
  }
  @derive Jason.Encoder
  defstruct [:run_id, :task_id]
end
