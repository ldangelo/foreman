defmodule ForemanServer.Events.TaskCreated do
  @derive Jason.Encoder
  defstruct [:task_id, :project_id]
end
