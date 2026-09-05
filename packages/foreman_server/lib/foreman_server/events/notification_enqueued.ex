defmodule ForemanServer.Events.NotificationEnqueued do
  @moduledoc "Notification accepted for provider delivery."
  @enforce_keys [
    :notification_id,
    :provider,
    :recipient,
    :event_class,
    :severity,
    :subject,
    :body,
    :correlation_id
  ]
  @type t :: %__MODULE__{
          notification_id: String.t(),
          provider: String.t(),
          recipient: String.t(),
          event_class: String.t(),
          severity: String.t(),
          subject: String.t(),
          body: String.t(),
          url: String.t() | nil,
          correlation_id: String.t(),
          run_id: String.t() | nil,
          sequence: non_neg_integer() | nil,
          enqueued_at_ms: non_neg_integer() | nil,
          metadata: map()
        }
  @derive Jason.Encoder
  defstruct [
    :notification_id,
    :provider,
    :recipient,
    :event_class,
    :severity,
    :subject,
    :body,
    :url,
    :correlation_id,
    :run_id,
    :sequence,
    :enqueued_at_ms,
    metadata: %{}
  ]
end
