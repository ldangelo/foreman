defmodule ForemanServer.Events.MergeGateApproved do
  @moduledoc """
  TRD-071: MergeGateApproved event — emitted by the Run aggregate when
  the `merge_approve` command is dispatched after human authorization.
  Unblocks `run.pr.merge` for the associated run.
  """
  @enforce_keys [:run_id, :approver, :approver_identity]
  @type t :: %__MODULE__{
          run_id: String.t(),
          approver: String.t(),
          approver_identity: String.t(),
          approved_at: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :approver, :approver_identity, approved_at: nil]
end
