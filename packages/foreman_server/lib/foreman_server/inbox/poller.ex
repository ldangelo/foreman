defmodule ForemanServer.Inbox.Poller do
  @moduledoc """
  TRD-006: Inbox poller that consumes `InboxItemStarted` and
  `InboxItemDeduped` events emitted by `SharedInbox.ingest/2`.

  The poller is intentionally minimal: it tracks ingestion stats in
  ETS so that downstream consumers (attach-bridge adapter, external
  trigger handler, etc.) can read them via `stats/0`. Real source
  fan-out is plugged in by callers via `attach_handler/2`.

  This module is the routing sink for `SharedInbox`. The dedupe
  contract is enforced upstream in `SharedInbox` + `DedupeTable`; the
  poller is read-side only.
  """

  use GenServer

  alias ForemanServer.Inbox.{
    InboxItemStarted,
    InboxItemDeduped
  }

  @table :foreman_inbox_poller_stats

  @doc """
  Read the current ingestion stats map.
  """
  @spec stats() :: map()
  def stats do
    ensure_table()
    :ets.tab2list(@table) |> Map.new()
  end

  @doc """
  Attach a handler module that receives every `InboxItemStarted` event
  for the given `source_module`. Handlers are invoked from the
  poller's process; raise to crash the poller (and trigger
  supervision restart).
  """
  @spec attach_handler(module(), module(), pid() | :auto) :: :ok
  def attach_handler(source_module, handler_module, target \\ :auto)
      when is_atom(source_module) and is_atom(handler_module) do
    target_pid =
      case target do
        :auto -> self()
        pid when is_pid(pid) -> pid
      end
    GenServer.call(__MODULE__, {:attach, source_module, handler_module, target_pid})
  end

  @doc """
  Detach a previously-attached handler.
  """
  @spec detach_handler(module()) :: :ok
  def detach_handler(source_module) when is_atom(source_module) do
    GenServer.call(__MODULE__, {:detach, source_module})
  end

  @doc "List current handler bindings."
  @spec handlers() :: [{module(), module()}]
  def handlers do
    GenServer.call(__MODULE__, :handlers)
  end

  @doc """
  Synchronous barrier — flushes pending casts. Returns current stats.
  Useful in tests to ensure async `cast` handlers have completed.
  """
  @spec synchronize() :: map()
  def synchronize do
    GenServer.call(__MODULE__, :sync)
  end

  # --- GenServer ---

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    ensure_table()
    {:ok, %{handlers: %{}}}
  end

  @impl true
  def handle_call({:attach, source, handler, target_pid}, _from, state) do
    binding = {handler, target_pid}
    {:reply, :ok, %{state | handlers: Map.put(state.handlers, source, binding)}}
  end
  def handle_call({:detach, source}, _from, state) do
    {:reply, :ok, %{state | handlers: Map.delete(state.handlers, source)}}
  end

  def handle_call(:handlers, _from, state) do
    {:reply, Map.to_list(state.handlers), state}
  end

  def handle_call(:sync, _from, state) do
    {:reply, stats(), state}
  end

  @impl true
  def handle_cast({:inbox_event, %InboxItemStarted{} = item}, state) do
    bump(:started)
    case Map.get(state.handlers, item.source) do



      nil -> :ok

      {handler, target_pid} -> dispatch(handler, target_pid, item)
    end

    {:noreply, state}
  end

  def handle_cast({:inbox_event, %InboxItemDeduped{} = item}, state) do
    bump(:deduped)
    _ = item
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  defp dispatch(handler, target_pid, %InboxItemStarted{} = item) do
    send(target_pid, {:inbox_item_started, handler, item})
    :ok
  end

  defp bump(key) do
    ensure_table()
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end

  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end
    end
  end
end
