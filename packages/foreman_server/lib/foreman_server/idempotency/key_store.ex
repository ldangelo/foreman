defmodule ForemanServer.Idempotency.KeyStore do
  @moduledoc """
  Durable idempotency key records with status {started, completed, ambiguous}.
  TRD-2026-4212be7e / RTE-T001 / TRD-075.
  """
  use GenServer
  @table :foreman_idempotency_keys

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  def mark_started(key, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:record, key, :started, metadata})
  end

  def mark_completed(key, result \\ %{}) do
    GenServer.call(__MODULE__, {:record, key, :completed, result})
  end

  def mark_ambiguous(key, reason \\ "timeout") do
    GenServer.call(__MODULE__, {:record, key, :ambiguous, %{reason: reason}})
  end

  def status(key) do
    case :ets.lookup(@table, key) do
      [{^key, status, _meta}] -> {:ok, status}
      [] -> :not_found
    end
  end

  @impl true
  def handle_call({:record, key, status, meta}, _from, state) do
    :ets.insert(@table, {key, status, meta})
    {:reply, :ok, state}
  end
end
