defmodule ForemanServer.Commands.RunSlotsRemoveWaiter do
  @enforce_keys [:run_id]
  defstruct [:run_id, :project_id]
end
