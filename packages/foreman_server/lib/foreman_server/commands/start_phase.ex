defmodule ForemanServer.Commands.StartPhase do
  @derive Jason.Encoder
  defstruct [:phase_id, :run_id]
end
