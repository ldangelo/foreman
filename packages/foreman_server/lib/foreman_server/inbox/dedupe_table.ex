defmodule ForemanServer.Inbox.DedupeTable do
  @moduledoc """
  TRD-001: Runtime dedupe cache for inbox items.

  A small in-memory ETS table keyed by `{source, correlation_id}`. The
  value is the `InboxItemStarted` event recorded when the correlation
  id was first seen. Entries expire after
  `ForemanServer.Inbox.SharedInbox.dedupe_window_seconds/0` seconds.

  The table is intentionally local — authoritative dedupe state lives
  in the event log (via `InboxItemStarted` events). This cache exists
  to short-circuit re-processing of duplicate ingestion events without
  re-reading the event store on every webhook.

  The table is owned by this GenServer so its lifetime is bound to the
  application supervisor, not to whichever transient caller triggered
  lazy initialisation. Without a long-lived owner, an ETS table created
  by a test process dies when that process exits, losing dedupe state
  for ingestions that span process boundaries.
  """

  use GenServer

  @table __MODULE__

  ## -- GenServer ---------------------------------------------------------

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # This is the only path that creates the ETS table. Public functions
    # do not call ensure_table/0 — that would let a transient caller
    # steal ownership during a GenServer restart, recreating the original
    # lazy-init race. If the GenServer is down, public functions will hit
    # :undefined and fail; the supervisor restarts us quickly under
    # :permanent.
    ensure_table()
    {:ok, %{}}
  end

  ## -- public API --------------------------------------------------------

  @doc """
  Returns `{:hit, item}` if a non-expired entry exists, otherwise
  `:miss`.
  """
  def lookup(source_module, correlation_id) do
    case :ets.lookup(@table, {source_module, correlation_id}) do
      [{_, item, expires_at}] ->
        if expires_at > System.system_time(:millisecond) do
          {:hit, item}
        else
          :ets.delete(@table, {source_module, correlation_id})
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc """
  Records an item in the dedupe table with an expiration based on the
  configured dedupe window.
  """
  def record(source_module, correlation_id, item) do
    ttl_ms = ForemanServer.Inbox.SharedInbox.dedupe_window_seconds() * 1000
    expires_at = System.system_time(:millisecond) + ttl_ms
    :ets.insert(@table, {{source_module, correlation_id}, item, expires_at})
    :ok
  end

  @doc """
  Clears the dedupe table. Useful for tests.
  """
  def clear do
    case :ets.info(@table) do
      :undefined -> :ok
      _ -> :ets.delete_all_objects(@table)
    end
  end

  @doc """
  Returns the current number of entries. Useful for tests.
  """
  def size do
    case :ets.info(@table) do
      :undefined -> 0
      _ -> :ets.info(@table, :size)
    end
  end

  ## -- private -----------------------------------------------------------

  defp ensure_table do
    case :ets.info(@table) do
      :undefined ->
        :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end
end
