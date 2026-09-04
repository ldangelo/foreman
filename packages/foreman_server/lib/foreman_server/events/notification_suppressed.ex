defmodule ForemanServer.Events.NotificationSuppressed do
  @moduledoc "Notification suppressed by disabled config or dedupe."
  @enforce_keys [:notification_id, :provider, :event_class, :correlation_id, :reason]
  @derive Jason.Encoder
  defstruct [:notification_id, :provider, :event_class, :correlation_id, :run_id, :reason, :sequence, metadata: %{}]
end
