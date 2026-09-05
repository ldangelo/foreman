defmodule ForemanServer.Events.NotificationDeliveryFailed do
  @moduledoc "Provider delivery attempt failed."
  @enforce_keys [:notification_id, :attempt_id, :provider, :correlation_id, :reason, :retryable?]
  @type t :: %__MODULE__{
          notification_id: String.t(),
          attempt_id: String.t(),
          provider: String.t(),
          correlation_id: String.t(),
          run_id: String.t() | nil,
          reason: String.t(),
          retryable?: boolean(),
          sequence: non_neg_integer() | nil,
          metadata: map()
        }
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
