defmodule ForemanServer.Inbox.InboxItemCorrelationId do
  @moduledoc """
  Behaviour for deriving a stable correlation-id from a command or raw payload.

  Both attach-bridge ingestion and external-trigger polling route through the
  same dedupe window; implement this behaviour so each source produces a
  consistent id that survives retries and at-least-once delivery.
  """

  @doc "Returns a stable, non-empty string id for dedupe and correlation."
  @callback correlation_id(command_or_payload :: map()) :: String.t()
end
