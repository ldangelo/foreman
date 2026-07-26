defmodule ForemanServer.Events.ProjectRegistered do
  @derive Jason.Encoder
  defstruct [:project_id, :path]
end
