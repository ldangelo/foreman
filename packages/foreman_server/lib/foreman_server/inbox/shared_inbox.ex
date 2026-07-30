defmodule ForemanServer.Inbox.SharedInbox do
  @moduledoc """
  Unified ingestion gateway for both attach-bridge and external-trigger sources.

  Both sources route through this facade; the correlation-id behaviour
  (attached by implementing `InboxItemCorrelationId`) provides a stable
  dedupe key so at-least-once delivery and retry do not produce duplicates.
  """

  alias ForemanServer.CommandRouter

  @doc """
  Submits an inbox item for dedupe checking and potential append.

  `impl` is the module implementing `InboxItemCorrelationId`.

  Returns `{:ok, event}` on success, `{:error, reason}` on failure.
  """
  @spec ingest(module(), map()) :: {:ok, map()} | {:error, term()}
  def ingest(impl, payload) when is_atom(impl) and is_map(payload) do
    with {:ok, correlation_id} <- derive_correlation_id(impl, payload),
         {:ok, source} <- derive_source(impl, payload),
         {:ok, event} <- dispatch(correlation_id, source, payload) do
      {:ok, event}
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

  # Flatten run_id out of payload so CommandRouter -> InboxThread sees it.
  # The original item payload (run context, body, etc.) stays at payload.payload.
  defp dispatch(correlation_id, source, payload) do
    run_id = Map.get(payload, :run_id) || Map.get(payload, "run_id")
    command = %{
      command_id: Map.get(payload, :idempotency_key) || "InboxItem:#{correlation_id}",
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
