defmodule ForemanServer.Commands.ExitWorker do
  @derive Jason.Encoder
  defstruct [:worker_id]
end
