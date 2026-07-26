defmodule ForemanServer.Events.PhaseStarted do
  @derive Jason.Encoder
  defstruct [:phase_id, :run_id]
end
