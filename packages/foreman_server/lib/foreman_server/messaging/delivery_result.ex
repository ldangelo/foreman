defmodule ForemanServer.Messaging.DeliveryResult do
  @moduledoc "Typed provider delivery result."
  @enforce_keys [:notification_id, :provider, :status, :retryable?]
  @derive Jason.Encoder
  defstruct [
    :notification_id,
    :provider,
    :status,
    :reason,
    :delivered_at,
    retryable?: false,
    metadata: %{}
  ]
end
