defmodule ForemanServer.TriggerPoller.StubSource do
  @moduledoc """
  Default source module for `TriggerPoller` when no application-config
  source is set. Implements `InboxItemCorrelationId` against the
  conventional `trigger_id` field.
  """
  @behaviour ForemanServer.Inbox.InboxItemCorrelationId

  @impl true
  def correlation_id(%{"trigger_id" => id}), do: id
  def correlation_id(%{trigger_id: id}), do: id
  def correlation_id(_), do: ""
end
