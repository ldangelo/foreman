defmodule ForemanServer.Events.PrAssociated do
  @moduledoc """
  TRD-016: Domain event emitted when an operator associates a PR with a
  run. The association is append-only — re-associating the same run to
  a different PR is allowed (operators occasionally retarget PRs); the
  `pr_url` field always reflects the most recent association.
  """
  @enforce_keys [:run_id, :pr_url]
  @type t :: %__MODULE__{
          run_id: String.t(),
          pr_url: String.t(),
          pr_number: non_neg_integer() | nil,
          associated_at: non_neg_integer() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :pr_url, :pr_number, associated_at: nil]
end
