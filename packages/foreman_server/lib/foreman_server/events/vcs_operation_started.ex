defmodule ForemanServer.Events.VcsOperationStarted do
  @moduledoc "Emitted when a VCS operation begins execution."
  @derive Jason.Encoder
  defstruct [:operation_id, :operation_type, :target]
end
