defmodule ForemanServer.Inbox.AttachBridgeAdapter do
  @moduledoc """
  TRD-014: Attach-bridge ingestion adapter.

  Normalises attach-bridge webhook payloads into an `InboxItemStarted`
  struct and routes them through `SharedInbox.ingest/2`.

  The adapter preserves specialized attach-bridge behaviour (streaming
  metadata, connection lifecycle) before normalization: callers can
  populate the optional `:metadata` field on the source module to keep
  these concerns out of the shared inbox path.

  The adapter does NOT extract correlation ids — that responsibility
  stays with the source module via the `InboxItemCorrelationId`
  behaviour. Payloads that don't carry an explicit `correlation_id`
  field will round-trip with an empty correlation id; the SharedInbox
  will then return `{:error, :no_correlation_id}`.

  ## Example

      defmodule MyApp.Integration.AttachBridgeSource do
        @behaviour ForemanServer.Inbox.InboxItemCorrelationId

        @impl true
        def correlation_id(%{"event_id" => id}), do: id
        def correlation_id(%{event_id: id}), do: id
      end

      AttachBridgeAdapter.ingest(MyApp.Integration.AttachBridgeSource, %{
        "correlation_id" => "evt-123",
        "stream_id" => "stream-abc",
        "connection_id" => "conn-1"
      })
  """

  alias ForemanServer.Inbox.{InboxItemStarted, SharedInbox}

  @type payload :: map()

  @doc """
  Normalise a raw attach-bridge payload into an `InboxItemStarted`
  struct. Streaming metadata and connection lifecycle are preserved in
  the `:payload` map under `:metadata` so downstream readers can recover
  them.
  """
  @spec normalize(payload()) :: InboxItemStarted.t()
  def normalize(payload) when is_map(payload) do
    %InboxItemStarted{
      correlation_id: extract_correlation_id(payload),
      source: payload[:source] || payload["source"],
      payload: attach_metadata(payload),
      timestamp: System.system_time(:second)
    }
  end

  @doc """
  Normalise the payload and route through `SharedInbox.ingest/2`.
  Returns the same response tuple as `SharedInbox.ingest/2`.
  """
  @spec ingest(module(), payload()) ::
          {:ok, :started, InboxItemStarted.t()}
          | {:ok, :deduped, term()}
          | {:error, term()}
  def ingest(source_module, payload) when is_atom(source_module) and is_map(payload) do
    case ensure_source(source_module, payload) do
      :ok -> SharedInbox.ingest(source_module, payload)
      {:error, _} = err -> err
    end
  end

  # -- private helpers ------------------------------------------------------

  defp extract_correlation_id(%{correlation_id: id}) when is_binary(id), do: id
  defp extract_correlation_id(%{"correlation_id" => id}) when is_binary(id), do: id
  defp extract_correlation_id(_), do: ""

  defp attach_metadata(payload) do
    streaming =
      Map.take(payload, [
        :stream_id,
        "stream_id",
        :connection_id,
        "connection_id",
        :connection_lifecycle,
        "connection_lifecycle"
      ])

    case streaming do
      empty when map_size(empty) == 0 -> Map.delete(payload, :metadata)
      _ -> Map.put(payload, :metadata, streaming)
    end
  end

  defp ensure_source(source_module, _payload) do
    if function_exported?(source_module, :correlation_id, 1) do
      :ok
    else
      {:error, {:unknown_source, source_module}}
    end
  end
end
