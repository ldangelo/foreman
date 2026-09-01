defmodule ForemanServer.Events.PhasePrRecorded do
  @moduledoc """
  Typed event emitted when a workflow phase records a phase-scoped pull request outcome.

  Phase PRs are separate from the final run PR association. They never populate
  the run-level `pr_url`; projections expose them through `phase_prs`.
  """

  @enforce_keys [
    :run_id,
    :phase_id,
    :phase_index,
    :phase_name,
    :status,
    :base_branch,
    :head_branch,
    :provider,
    :recorded_at
  ]

  @type status :: String.t()

  @type t :: %__MODULE__{
          run_id: String.t(),
          phase_id: String.t(),
          phase_index: non_neg_integer(),
          phase_name: String.t(),
          status: status(),
          pr_url: String.t() | nil,
          pr_number: non_neg_integer() | nil,
          base_branch: String.t(),
          head_branch: String.t(),
          provider: String.t(),
          reason: String.t() | nil,
          recorded_at: String.t()
        }

  @derive Jason.Encoder
  defstruct [
    :run_id,
    :phase_id,
    :phase_index,
    :phase_name,
    :status,
    :pr_url,
    :pr_number,
    :base_branch,
    :head_branch,
    :provider,
    :reason,
    :recorded_at
  ]
end
