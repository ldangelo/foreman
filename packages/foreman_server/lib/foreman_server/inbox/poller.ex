defmodule ForemanServer.Inbox.Poller do
  @moduledoc """
  Inbox item routing boundary.

  Pollers (external-trigger pollers, attach-bridge hooks) submit normalized items
  here.  This module dispatches to `CommandRouter` with a per-attempt `command_id`
  so EventStore idempotency never blocks retries before the `InboxThread` aggregate
  can emit `InboxItemDeduped` for a stable `correlation_id`.
  """

  alias ForemanServer.CommandRouter

  @doc """
  Submits a normalized inbox item for dedupe checking and potential append.

  `correlation_id` is the stable dedupe key from `InboxItemCorrelationId`.
  `payload` is the original raw item.
  """
  @spec submit(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def submit(correlation_id, source, payload)
      when is_binary(correlation_id) and is_binary(source) and is_map(payload) do
    run_id = Map.get(payload, :run_id) || Map.get(payload, "run_id")

    command = %{
      # unique per delivery attempt — EventStore idempotency is per attempt,
      # not per item; InboxThread dedupes on correlation_id instead
      command_id: "InboxItem:#{correlation_id}:#{System.unique_integer([:positive])}",
      command_type: "inbox.item.start",
      payload: %{
        run_id: run_id,
        correlation_id: correlation_id,
        source: source,
        payload: payload
      }
    }

    CommandRouter.handle(command)
  end
end
