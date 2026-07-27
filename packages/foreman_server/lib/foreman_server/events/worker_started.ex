defmodule ForemanServer.Events.WorkerStarted do
  @enforce_keys [:worker_id, :run_id]
  @type t :: %__MODULE__{
    worker_id: String.t(),
    run_id: String.t()
  }
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id]
end
