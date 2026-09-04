defmodule ForemanServer.Messaging.Config do
  @moduledoc "Resolved outbound messaging config."

  @enforce_keys [:enabled?, :provider, :event_classes, :dedupe_window_ms, :run_update_rate_limit_ms]
  @derive Jason.Encoder
  defstruct [:enabled?, :provider, :event_classes, :dedupe_window_ms, :run_update_rate_limit_ms, :destination]
end
