defmodule ForemanServer.Events.WorkerStderr do
  @moduledoc "Typed event emitted when a worker writes to stderr."
  @enforce_keys [:worker_id, :run_id]
  @type t :: %__MODULE__{
          worker_id: String.t(),
          run_id: String.t(),
          sequence: non_neg_integer() | nil,
          line: String.t() | nil,
          timestamp: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id, :sequence, :line, :timestamp]
end
