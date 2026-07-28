defmodule ForemanServer.Events.WorkerHeartbeat do
  @enforce_keys [:run_id, :worker_id]
  @type t :: %__MODULE__{
    run_id: String.t(),
    worker_id: String.t()
  }
  @derive Jason.Encoder
  defstruct [:run_id, :worker_id]
end
