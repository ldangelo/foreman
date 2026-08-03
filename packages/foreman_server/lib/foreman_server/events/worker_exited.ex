defmodule ForemanServer.Events.WorkerExited do
  @moduledoc "Typed event emitted when a worker process has exited."
  @enforce_keys [:worker_id]
  @type t :: %__MODULE__{
          worker_id: String.t(),
          run_id: String.t() | nil,
          sequence: non_neg_integer() | nil,
          reason: term() | nil
        }
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id, :sequence, :reason]
end