defmodule ForemanServer.Events.NotificationDeliveryFailed do
  @moduledoc "Provider delivery attempt failed."
  @enforce_keys [:notification_id, :attempt_id, :provider, :correlation_id, :reason, :retryable?]
  @derive Jason.Encoder
  defstruct [
    :notification_id,
    :attempt_id,
    :provider,
    :correlation_id,
    :run_id,
    :reason,
    :retryable?,
    :sequence,
    metadata: %{}
  ]
end
