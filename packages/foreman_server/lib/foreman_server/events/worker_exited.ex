defmodule ForemanServer.Events.WorkerExited do
  @derive Jason.Encoder
  defstruct [:worker_id]
end
