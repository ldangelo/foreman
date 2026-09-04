defmodule ForemanServer.Events.NotificationDeliveryAttempted do
  @moduledoc "Provider delivery attempt started."
  @enforce_keys [:notification_id, :attempt_id, :provider, :correlation_id]
  @derive Jason.Encoder
  defstruct [
    :notification_id,
    :attempt_id,
    :provider,
    :correlation_id,
    :run_id,
    :sequence,
    metadata: %{}
  ]
end
