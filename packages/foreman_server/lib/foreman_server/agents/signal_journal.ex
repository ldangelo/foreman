defmodule ForemanServer.Agents.SignalJournal do
  @moduledoc """
  Persistent journal of published signals for replay on restart.
  TRD-2026-4212be7e / JSI-T004 / TRD-022.
  """
  use GenServer
  @table :foreman_signal_journal

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  def record(topic, payload, opts \\ []) do
    entry = %{
      id: "sig-#{System.unique_integer([:positive])}",
      topic: topic,
      payload: payload,
      timestamp: System.system_time(:millisecond),
      delivery: Keyword.get(opts, :delivery, :pending)
    }

    GenServer.call(__MODULE__, {:record, entry})
  end

  def replay(topic \\ nil), do: GenServer.call(__MODULE__, {:replay, topic})

  @doc """
  Clear all entries from the journal. Primarily intended for testing.
  """
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def handle_call({:record, entry}, _from, state) do
    :ets.insert(@table, {entry.id, entry})
    {:reply, {:ok, entry.id}, state}
  end

  def handle_call({:replay, nil}, _from, state) do
    all = :ets.tab2list(@table) |> Enum.map(fn {_id, e} -> e end)
    {:reply, all, state}
  end

  def handle_call({:replay, topic}, _from, state) do
    matched =
      :ets.tab2list(@table)
      |> Enum.map(fn {_id, e} -> e end)
      |> Enum.filter(fn e -> e.topic == topic end)

    {:reply, matched, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
