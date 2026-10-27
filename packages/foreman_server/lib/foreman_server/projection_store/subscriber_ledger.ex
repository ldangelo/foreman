defmodule ForemanServer.ProjectionStore.SubscriberLedger do
  @moduledoc """
  Owns the durable record of who subscribed to the named `ForemanServer.ProjectionStore`.

  Subscribers (`Workflow.Dispatcher`, the PR watcher, the notifier, ...) call
  `ProjectionStore.subscribe/1` once, at their own `init/1`. The store's supervisor restarts a
  crashed store with fresh state, so a subscriber list kept only in the store's state is lost:
  every boot-time subscriber stays alive but never receives another event, and the server
  silently stops dispatching runs (foreman-m75e9).

  This process lives *outside* the store (started before it, restarted independently) and owns
  a public ETS table of `{subscriber_pid, replay_existing?}`. The store writes to it on
  `subscribe` and reads it back in `init/1`, so subscribers never have to notice a store
  restart. Entries whose process died are dropped on read.
  """

  use GenServer

  @table __MODULE__

  @type entry :: %{pid: pid(), replay_existing: boolean()}

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "True when the ledger table exists (the ledger process is running)."
  @spec available?() :: boolean()
  def available?, do: :ets.whereis(@table) != :undefined

  @doc "Record `pid` as a subscriber. `replay_existing` sticks once true."
  @spec put(pid(), boolean()) :: :ok
  def put(pid, replay_existing) when is_pid(pid) and is_boolean(replay_existing) do
    if available?() do
      previous = match?([{^pid, true}], :ets.lookup(@table, pid))
      :ets.insert(@table, {pid, replay_existing or previous})
    end

    :ok
  end

  @doc "Forget `pid`."
  @spec delete(pid()) :: :ok
  def delete(pid) when is_pid(pid) do
    if available?(), do: :ets.delete(@table, pid)
    :ok
  end

  @doc "Every recorded subscriber whose process is still alive; dead ones are dropped."
  @spec list() :: [entry()]
  def list do
    if available?() do
      Enum.flat_map(:ets.tab2list(@table), fn {pid, replay_existing} ->
        if Process.alive?(pid) do
          [%{pid: pid, replay_existing: replay_existing}]
        else
          :ets.delete(@table, pid)
          []
        end
      end)
    else
      []
    end
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, :ok}
  end
end
