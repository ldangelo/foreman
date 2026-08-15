defmodule ForemanServer.Commands.RunSlotsRelease do
  @enforce_keys [:run_id]
  defstruct [:run_id, :capacity]
end
