defmodule ForemanServer.Events.RunFlaggedStuck do
  @moduledoc """
  Emitted when the StuckDetector flags an active run as stuck (no phase or
  worker event for `threshold_ms` wall-clock milliseconds).

  Both fields are required.
  """
  @enforce_keys [:run_id, :flagged_at]
  @type t :: %__MODULE__{
          run_id: String.t(),
          flagged_at: non_neg_integer()
        }
  @derive Jason.Encoder
  defstruct [:run_id, :flagged_at]
end
