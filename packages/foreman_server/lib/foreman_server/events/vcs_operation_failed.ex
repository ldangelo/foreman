defmodule ForemanServer.Events.VcsOperationFailed do
  @moduledoc "Emitted when a VCS operation fails after retries are exhausted."
  @derive Jason.Encoder
  defstruct [:operation_id, :operation_type, :target, :error, :retries]
end
