defmodule ForemanServer.Review.BeadSink.Result do
  @moduledoc """
  Outcome of `ForemanServer.Review.BeadSink.publish/2`: the ids of the gap beads
  filed for the verdict and an optional note for the recorded review summary
  (suppressed or partially failed gap filing, a skipped bead step).
  """

  @enforce_keys [:gap_bead_ids, :note]
  @type t :: %__MODULE__{gap_bead_ids: [String.t()], note: String.t() | nil}
  defstruct [:gap_bead_ids, :note]
end
