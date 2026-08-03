defmodule ForemanServer.Events.ScheduledFireSkipped do
  @moduledoc "Emitted when a scheduled fire is abandoned (e.g. run already completed)."
  @derive Jason.Encoder
  defstruct [:intent_id, :reason]
end
