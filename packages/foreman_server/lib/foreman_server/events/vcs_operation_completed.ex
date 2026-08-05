defmodule ForemanServer.Events.VcsOperationCompleted do
  @moduledoc "Emitted when a VCS operation completes successfully."
  @derive Jason.Encoder
  defstruct [:operation_id, :operation_type, :target, :result]
end
