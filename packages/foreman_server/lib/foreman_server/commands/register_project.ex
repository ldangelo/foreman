defmodule ForemanServer.Commands.RegisterProject do
  @derive Jason.Encoder
  defstruct [:project_id, :path]
end
