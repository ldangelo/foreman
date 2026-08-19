defmodule ForemanServer.Events.MergeGatePending do
  @moduledoc """
  TRD-071: MergeGatePending event — emitted by the Run aggregate after
  `PrReady` is received (Ensemble reports PR creation). The run is paused
  at the merge gate and requires explicit human approval via
  `merge_approve` before `run.pr.merge` is accepted.
  """
  @enforce_keys [:run_id, :pr_url]
  @type t :: %__MODULE__{
          run_id: String.t(),
          pr_url: String.t(),
          pr_number: non_neg_integer() | nil,
          paused_at: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :pr_url, pr_number: nil, paused_at: nil]
end
