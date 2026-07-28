defmodule ForemanServer.Events.WorkerRestarted do
  @enforce_keys [:run_id]
  @type t :: %__MODULE__{
    run_id: String.t()
  }
  @derive Jason.Encoder
  defstruct [:run_id]
end
