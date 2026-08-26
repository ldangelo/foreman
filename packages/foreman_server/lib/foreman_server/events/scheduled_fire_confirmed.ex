defmodule ForemanServer.Events.ScheduledFireConfirmed do
  @moduledoc "Emitted when a worker confirms pickup of a scheduled fire intent."
  @derive Jason.Encoder
  defstruct [:intent_id, :confirmed_at]
end
