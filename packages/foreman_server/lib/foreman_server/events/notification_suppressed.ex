defmodule ForemanServer.Events.NotificationSuppressed do
  @moduledoc "Notification suppressed by disabled config or dedupe."
  @enforce_keys [:notification_id, :provider, :event_class, :correlation_id, :reason]
  @type t :: %__MODULE__{
          notification_id: String.t(),
          provider: String.t(),
          event_class: String.t(),
          correlation_id: String.t(),
          run_id: String.t() | nil,
          reason: String.t(),
          sequence: non_neg_integer() | nil,
          metadata: map()
        }
  @derive Jason.Encoder
  defstruct [
    :notification_id,
    :provider,
    :event_class,
    :correlation_id,
    :run_id,
    :reason,
    :sequence,
    metadata: %{}
  ]
end
