defmodule ForemanServer.Events.TaskRunTerminated do
  @moduledoc """
  Typed event emitted when a previously-bound run reaches a terminal
  state and the operator (or automated recovery) acknowledges that the
  run will never produce a `RunCompleted` / `RunFailed` event for the
  bound task.

  It unlocks `task.retry` so the same task can be re-approved and
  dispatched against a fresh run on boot.
  """

  @enforce_keys [:task_id, :run_id]
  @type t :: %__MODULE__{
          task_id: String.t(),
          run_id: String.t(),
          reason: String.t() | nil,
          acknowledged_at: String.t() | nil,
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:task_id, :run_id, :reason, :acknowledged_at, :sequence]
end
