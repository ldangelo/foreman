defmodule ForemanServer.Commands.RunSlotsAcquire do
  @enforce_keys [:run_id, :capacity]
  defstruct [:run_id, :capacity]
end
