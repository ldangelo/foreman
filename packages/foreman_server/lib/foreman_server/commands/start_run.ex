defmodule ForemanServer.Commands.StartRun do
  @derive Jason.Encoder
  defstruct [:run_id, :task_id]
end
