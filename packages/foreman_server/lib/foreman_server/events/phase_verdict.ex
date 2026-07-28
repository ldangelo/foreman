defmodule ForemanServer.Events.PhaseVerdict do
  @enforce_keys [:run_id, :phase_id]
  @type t :: %__MODULE__{
    run_id: String.t(),
    phase_id: String.t(),
    verdict: String.t() | nil,
    status: String.t() | nil,
    final: boolean() | nil
  }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :phase_id,
    :verdict,
    :status,
    final: true
  ]
end
