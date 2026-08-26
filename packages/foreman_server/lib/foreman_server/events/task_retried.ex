defmodule ForemanServer.Events.TaskRetried do
  @moduledoc """
  Typed event emitted when the operator (or automated recovery)
  acknowledges a bound run is terminal and clears the task back to a
  fresh `open` lifecycle, ready for re-approval and dispatch.

  The unconditional apply resets all run-bound fields so a `task.approve`
  path can rebind a fresh `run_id` / `approval_id` pair without
  reapplying a stale `TaskApproved`.
  """

  @enforce_keys [:task_id, :previous_run_id]
  @type t :: %__MODULE__{
          task_id: String.t(),
          previous_run_id: String.t() | nil,
          reason: String.t() | nil,
          retried_at: String.t() | nil,
          sequence: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:task_id, :previous_run_id, :reason, :retried_at, :sequence]
end
