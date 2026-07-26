defmodule ForemanServer.Events.WorkerStarted do
  @derive Jason.Encoder
  defstruct [:worker_id, :run_id]
end
