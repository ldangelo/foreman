defmodule ForemanServer.Events.ProjectArchived do
  @derive Jason.Encoder
  defstruct [:project_id]
end
