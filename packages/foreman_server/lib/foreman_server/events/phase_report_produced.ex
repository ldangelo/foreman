defmodule ForemanServer.Events.PhaseReportProduced do
  @enforce_keys [:run_id, :phase_id]
  @type t :: %__MODULE__{
    run_id: String.t(),
    phase_id: String.t(),
    report_id: String.t() | nil,
    metadata: map() | nil
  }
  @derive Jason.Encoder
  defstruct [
    :run_id,
    :phase_id,
    :report_id,
    :metadata
  ]
end
