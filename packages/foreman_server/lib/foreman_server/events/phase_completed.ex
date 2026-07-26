defmodule ForemanServer.Events.PhaseCompleted do
  @derive Jason.Encoder
  defstruct [:phase_id]
end
