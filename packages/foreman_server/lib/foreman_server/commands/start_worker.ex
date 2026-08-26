defmodule ForemanServer.Commands.StartWorker do
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id]
end
