defmodule ForemanServer.Events.TaskClosed do
  @derive Jason.Encoder
  defstruct [:task_id]
end
