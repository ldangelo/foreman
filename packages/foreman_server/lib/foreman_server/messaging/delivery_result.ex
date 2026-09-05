defmodule ForemanServer.Messaging.DeliveryResult do
  @moduledoc "Typed provider delivery result."
  @enforce_keys [:notification_id, :provider, :status, :retryable?]
  @type t :: %__MODULE__{
          notification_id: String.t(),
          provider: atom(),
          status: atom(),
          reason: String.t() | nil,
          delivered_at: String.t() | nil,
          retryable?: boolean(),
          metadata: map()
        }
  @derive Jason.Encoder
  defstruct [
    :notification_id,
    :provider,
    :status,
    :reason,
    :delivered_at,
    :retryable?,
    metadata: %{}
  ]
end
