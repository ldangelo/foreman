defmodule ForemanServer.Events.NotificationDeliverySucceeded do
  @moduledoc "Provider delivery attempt succeeded."
  @enforce_keys [:notification_id, :attempt_id, :provider, :correlation_id]
  @type t :: %__MODULE__{
          notification_id: String.t(),
          attempt_id: String.t(),
          provider: String.t(),
          correlation_id: String.t(),
          run_id: String.t() | nil,
          delivered_at: String.t() | nil,
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
    :delivered_at,
    :sequence,
    metadata: %{}
  ]
end
