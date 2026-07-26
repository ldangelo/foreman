defmodule ForemanServer.Commands.CompleteRun do
  @derive Jason.Encoder
  defstruct [:run_id]
end
