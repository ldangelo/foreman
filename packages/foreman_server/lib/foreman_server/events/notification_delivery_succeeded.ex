defmodule ForemanServer.Events.NotificationDeliverySucceeded do
  @moduledoc "Provider delivery attempt succeeded."
  @enforce_keys [:notification_id, :attempt_id, :provider, :correlation_id]
  @derive Jason.Encoder
  defstruct [
    :notification_id,
    :attempt_id,
    :provider,
    :correlation_id,
    :run_id,
    :delivered_at,
    :sequence,
    metadata: %{}
  ]
end
