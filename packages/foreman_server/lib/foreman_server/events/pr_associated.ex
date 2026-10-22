defmodule ForemanServer.Events.PrAssociated do
  @moduledoc """
  TRD-016: Domain event emitted when an operator associates a PR with a
  run. The association is append-only — re-associating the same run to
  a different PR is allowed (operators occasionally retarget PRs); the
  `pr_url` field always reflects the most recent association.
  """
  # `repo_id`: absent = the run's primary repo (E12); declared for strict decode.
  @enforce_keys [:run_id, :pr_url]
  @type t :: %__MODULE__{
          run_id: String.t(),
          pr_url: String.t(),
          pr_number: non_neg_integer() | nil,
          associated_at: non_neg_integer() | nil,
          repo_id: String.t() | nil
        }
  @derive Jason.Encoder
  defstruct [:run_id, :pr_url, :pr_number, :repo_id, associated_at: nil]
end
