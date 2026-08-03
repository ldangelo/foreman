defmodule ForemanServer.Events.WorkerUnresponsive do
  @moduledoc """
  Typed event emitted when a worker has not heartbeat within the
  configured liveness window. Carries the liveness deadline and the
  timestamp of the last observed heartbeat (if any).
  """
  @enforce_keys [:worker_id, :run_id]
  @type t :: %__MODULE__{
          worker_id: String.t(),
          run_id: String.t(),
          sequence: non_neg_integer(),
          last_heartbeat_at: non_neg_integer() | nil,
          timeout_ms: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id, :sequence, :last_heartbeat_at, :timeout_ms]
end