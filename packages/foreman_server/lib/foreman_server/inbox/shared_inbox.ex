defmodule ForemanServer.Inbox.SharedInbox do
  @moduledoc """
  Unified ingestion gateway for both attach-bridge and external-trigger sources.

  Normalizes incoming items (via the `InboxItemCorrelationId` behaviour) then
  delegates routing to `Inbox.Poller`, which dispatches to `CommandRouter`.
  """

  alias ForemanServer.{EventStore, Inbox.Poller}

  @doc """
  Normalizes an incoming item and routes it through the inbox poller.

  `impl` is the module implementing `InboxItemCorrelationId`.

  Returns `{:ok, %{event: event}}` on success or dedupe hit.  On a dedupe hit,
  `existing_item` is the latest `InboxItemStarted` payload for that correlation_id
  within the run stream — the "existing delivery status".
  """
  @spec ingest(module(), map()) :: {:ok, %{event: map()}} | {:error, term()}
  def ingest(impl, payload) when is_atom(impl) and is_map(payload) do
    with {:ok, correlation_id} <- derive_correlation_id(impl, payload),
         {:ok, source} <- derive_source(impl, payload),
         {:ok, %{event: event}} <- Poller.submit(correlation_id, source, payload) do
      result = %{event: event}

      if event.event_type == "InboxItemDeduped" do
        Map.put(result, :existing_item, find_existing_item(correlation_id, payload))
      else
        result
      end
      |> then(&{:ok, &1})
    end
  end

  defp derive_correlation_id(impl, payload) do
    case impl.correlation_id(payload) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, {:invalid_correlation_id, impl}}
    end
  rescue
    UndefinedFunctionError -> {:error, {:not_inbox_correlation_id_impl, impl}}
  end

  defp derive_source(impl, payload) do
    source = Map.get(payload, :source) || Map.get(payload, "source") || Atom.to_string(impl)
    if source != "", do: {:ok, source}, else: {:error, :missing_source}
  end

  # Reverse-scans the stream for the latest InboxItemStarted matching correlation_id.
  defp find_existing_item(correlation_id, payload) do
    run_id = Map.get(payload, :run_id) || Map.get(payload, "run_id")
    stream_id = "inbox:#{run_id}"

    events = EventStore.stream(stream_id)

    events
    |> Enum.reverse()
    |> Enum.find(fn e ->
      e.event_type == "InboxItemStarted" and
        e.payload.correlation_id == correlation_id
    end)
    |> case do
      nil -> nil
      event -> event.payload
    end
  end
end
