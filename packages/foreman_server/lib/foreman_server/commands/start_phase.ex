defmodule ForemanServer.Commands.StartPhase do
  @derive Jason.Encoder
  defstruct [:phase_id, :run_id, :index, :name, :attempt, :artifact_template]
end
