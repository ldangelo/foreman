defmodule ForemanServer.Events.ScheduledFireConfirmed do
  @moduledoc "Emitted when a scheduled fire intent is confirmed complete."
  @enforce_keys [:intent_id]
  @type t :: %__MODULE__{intent_id: String.t(), confirmed_at: String.t() | nil}
  @derive Jason.Encoder
  defstruct [:intent_id, :confirmed_at]
end
