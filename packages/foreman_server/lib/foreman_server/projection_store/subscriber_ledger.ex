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

  If the *ledger* dies instead, the supervisor restarts it with an empty table. The store keeps
  its current subscribers (and replay flags) in its own state, so `init/1` here tells a running
  store `:subscriber_ledger_restarted` and the store re-puts every subscriber (foreman-z2tld).
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

    # A restarted ledger has an empty table; the live store knows its current subscribers and
    # writes them back (foreman-z2tld). At first boot the store is not up yet: nothing to do.
    # Limitation: this covers ONE failure (ledger dies, store alive). If the ledger dies while the
    # store is itself restarting, this message is lost and the store's `restore_subscribers/1`
    # read an empty table; closing that needs a table that outlives both processes (out of scope).
    if store = Process.whereis(ForemanServer.ProjectionStore),
      do: send(store, :subscriber_ledger_restarted)

    {:ok, :ok}
  end
end
