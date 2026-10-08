defmodule ForemanServer.Events.JobsiteSandboxReleased do
  @moduledoc "Typed event emitted when a jobsite's sandbox has been torn down."
  @enforce_keys [:jobsite_id]
  @type t :: %__MODULE__{jobsite_id: String.t(), container_id: String.t() | nil}
  @derive Jason.Encoder
  defstruct [:jobsite_id, :container_id]
end
