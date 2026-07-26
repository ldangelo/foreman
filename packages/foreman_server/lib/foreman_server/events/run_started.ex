defmodule ForemanServer.Events.RunStarted do
  @derive Jason.Encoder
  defstruct [:run_id, :task_id]
end
