defmodule ForemanServer.TestSupport.BlockCommand do
  @moduledoc "Test-only blocking command. Aggregates handle it in execute/2 via selective receive."
  @derive Jason.Encoder
  defstruct [:aggregate_id, :aggregate_type, :ref, :notify_pid]
end
