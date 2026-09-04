defmodule ForemanServer.Events.NotificationEnqueued do
  @moduledoc "Notification accepted for provider delivery."
  @enforce_keys [:notification_id, :provider, :recipient, :event_class, :severity, :subject, :body, :correlation_id]
  @derive Jason.Encoder
  defstruct [:notification_id, :provider, :recipient, :event_class, :severity, :subject, :body, :url, :correlation_id, :run_id, :sequence, metadata: %{}]
end
