defmodule ForemanServer.Events.WorkerHeartbeat do
  @moduledoc "Typed event emitted when a worker signals liveness."
  @enforce_keys [:worker_id, :run_id]
  @type t :: %__MODULE__{
          worker_id: String.t(),
          run_id: String.t(),
          sequence: non_neg_integer(),
          timestamp: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id, :sequence, :timestamp]
end
