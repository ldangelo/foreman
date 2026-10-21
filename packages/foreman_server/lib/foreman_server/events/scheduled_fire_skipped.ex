defmodule ForemanServer.Events.ScheduledFireSkipped do
  @moduledoc "Emitted when a recorded fire intent is abandoned (e.g. its schedule was deleted)."
  @enforce_keys [:intent_id]
  @type t :: %__MODULE__{intent_id: String.t(), reason: String.t() | nil}
  @derive Jason.Encoder
  defstruct [:intent_id, :reason]
end
