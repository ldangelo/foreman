defmodule ForemanServer.Commands.CloseTask do
  @derive Jason.Encoder
  defstruct [:task_id]
end
