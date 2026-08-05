defmodule ForemanServer.Inbox.InboxItemCorrelationId do
  @moduledoc """
  TRD-001: Behaviour for sources that produce inbox items.

  Each source implements `correlation_id/1` to derive a stable dedupe
  key from the raw payload. The key MUST be deterministic for a given
  logical item (e.g. a webhook event id) and MUST be a non-empty
  binary.

  ## Example

      defmodule MyApp.Integration.AttachBridgeSource do
        @behaviour ForemanServer.Inbox.InboxItemCorrelationId

        @impl true
        def correlation_id(payload) do
          Map.get(payload, "event_id") || Map.get(payload, :event_id)
        end
      end
  """

  @callback correlation_id(payload :: map()) :: String.t() | nil
end
