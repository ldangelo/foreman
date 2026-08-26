defmodule ForemanServer.Inbox.SharedInbox do
  @moduledoc """
  TRD-001: SharedInbox command and event schema for unified ingestion.

  Provides:

    * `InboxItemStarted` / `InboxItemDeduped` event structs (the typed
      domain event schemas for inbox ingestion).
    * `StartInboxItem` command struct (the canonical command every
      ingestion source emits).
    * `InboxItemCorrelationId` behaviour — sources implement
      `correlation_id/1` to derive a stable dedupe key.
    * `SharedInbox.ingest/2` — normalises any ingestion source to an
      `InboxItem` and routes it through the dedupe table. On hit, emits
      `InboxItemDeduped` and returns the existing delivery status; on
      miss, emits `InboxItemStarted` and returns `:started`.
    * `:inbox_dedupe_window_seconds` configuration (default 300s).

  The schema is intentionally minimal so both attach-bridge ingestion
  (TRD-014) and external trigger polling (TRD-015) can depend on it
  without depending on each other. Sources register an
  `InboxItemCorrelationId` implementation and call `ingest/2`.
  """

  alias ForemanServer.Inbox.{DedupeTable, InboxItemStarted, InboxItemDeduped}

  @default_dedupe_window_seconds 300

  @doc """
  Returns the configured dedupe window in seconds, or the default.
  """
  def dedupe_window_seconds do
    Application.get_env(
      :foreman_server,
      :inbox_dedupe_window_seconds,
      @default_dedupe_window_seconds
    )
  end

  @doc """
  Ingest a raw payload from a registered source.

  Returns one of:

    * `{:ok, :started, %InboxItemStarted{}}` — first time the
      correlation id was seen in the current dedupe window.
    * `{:ok, :deduped, %InboxItemDeduped{}}` — duplicate within the
      dedupe window; the existing delivery status is returned.
    * `{:error, :no_correlation_id}` — the source's `correlation_id/1`
      returned `nil`/`""` and the payload could not be normalised.
  """
  @spec ingest(module(), map()) ::
          {:ok, :started, InboxItemStarted.t()}
          | {:ok, :deduped, InboxItemDeduped.t()}
          | {:error, :no_correlation_id}
          | {:error, {:unknown_source, module()}}
  def ingest(source_module, payload) when is_atom(source_module) and is_map(payload) do
    _ = Code.ensure_loaded(source_module)

    cond do
      not function_exported?(source_module, :correlation_id, 1) ->
        {:error, {:unknown_source, source_module}}

      true ->
        case source_module.correlation_id(payload) do
          correlation_id when is_binary(correlation_id) and correlation_id != "" ->
            do_ingest(source_module, payload, correlation_id)

          _ ->
            {:error, :no_correlation_id}
        end
    end
  end

  defp do_ingest(source_module, payload, correlation_id) do
    case DedupeTable.lookup(source_module, correlation_id) do
      {:hit, existing} ->
        deduped = %InboxItemDeduped{
          correlation_id: correlation_id,
          source: source_module,
          existing: existing
        }

        notify(:deduped, deduped)
        {:ok, :deduped, deduped}

      :miss ->
        item = %InboxItemStarted{
          correlation_id: correlation_id,
          source: source_module,
          payload: payload,
          timestamp: System.system_time(:millisecond)
        }

        DedupeTable.record(source_module, correlation_id, item)
        notify(:started, item)
        {:ok, :started, item}
    end
  end

  # Route the inbox event to the running Poller (TRD-006). The Poller
  # is supervised by ForemanServer.Application; if it is not running
  # (eg. in a minimal test setup), the call is silently dropped.
  defp notify(kind, event) do
    alias ForemanServer.Inbox.Poller

    if Process.whereis(Poller) do
      GenServer.cast(Poller, {:inbox_event, event})
    end

    _ = kind
    :ok
  end
end
