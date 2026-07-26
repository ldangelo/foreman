defmodule ForemanServer.Commands.CreateTask do
  @derive Jason.Encoder
  defstruct [:task_id, :project_id]
end
