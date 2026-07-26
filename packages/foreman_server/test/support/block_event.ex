defmodule ForemanServer.TestSupport.BlockEvent do
  @moduledoc "Test-only event produced when a blocked execute/2 is released via {:release, ref}."
  @derive Jason.Encoder
  defstruct [:aggregate_id, :aggregate_type]
end
