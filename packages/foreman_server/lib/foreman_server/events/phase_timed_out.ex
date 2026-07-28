defmodule ForemanServer.Events.PhaseTimedOut do
  @enforce_keys [:run_id, :phase_id]
  @type t :: %__MODULE__{
    run_id: String.t(),
    phase_id: String.t()
  }
  @derive Jason.Encoder
  defstruct [:run_id, :phase_id]
end
