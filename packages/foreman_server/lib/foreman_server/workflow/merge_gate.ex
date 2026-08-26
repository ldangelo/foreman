defmodule ForemanServer.Workflow.MergeGate do
  @moduledoc """
  Merge gate: pauses after Ensemble reports PR creation; requires explicit human approval before merge.
  Extends TRD-014 VCS/PR state machine.
  TRD-2026-4212be7e / MGH-T001 / TRD-071.
  """
  use GenServer
  require Logger

  @table :foreman_merge_gate

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Clears all pending/approved entries. For test isolation now that MergeGate is a supervised app singleton."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, %{}}
  end

  def request_approval(pr_url, requested_by) do
    GenServer.call(__MODULE__, {:request, pr_url, requested_by})
  end

  def approve(pr_url, approver, approver_identity) do
    GenServer.call(__MODULE__, {:approve, pr_url, approver, approver_identity})
  end

  def approve_by_key(key, approver, approver_identity) do
    GenServer.call(__MODULE__, {:approve_by_key, key, approver, approver_identity})
  end

  def pending do
    :ets.tab2list(@table)
    |> Enum.filter(fn {_url, req} -> req.status == :pending end)
    |> Enum.map(fn {url, _req} -> url end)
  end

  @doc "Returns true if the given run/identity key has a pending merge gate entry."
  @spec pending_for_key?(String.t()) :: boolean()
  def pending_for_key?(key) when is_binary(key) do
    :ets.tab2list(@table)
    |> Enum.any?(fn {_url, req} -> req.requested_by == key and req.status == :pending end)
  end

  @doc "Returns true if the given run key has an approved merge gate entry."
  @spec approved?(String.t()) :: boolean()
  def approved?(key) when is_binary(key) do
    :ets.tab2list(@table)
    |> Enum.any?(fn {_url, req} -> req.requested_by == key and req.status == :approved end)
  end

  @impl true
  def handle_call({:request, pr_url, requested_by}, _from, state) do
    Logger.info("Merge approval requested: pr=#{pr_url} by=#{requested_by}")
    record = %{status: :pending, requested_by: requested_by, approver: nil, approver_identity: nil, requested_at: System.system_time(:millisecond), approved_at: nil}
    :ets.insert(@table, {pr_url, record})
    {:reply, {:ok, :pending}, state}
  end

  def handle_call({:approve, pr_url, approver, identity}, _from, state) do
    case :ets.lookup(@table, pr_url) do
      [{^pr_url, req}] ->
        updated = %{req | status: :approved, approver: approver, approver_identity: identity, approved_at: System.system_time(:millisecond)}
        :ets.insert(@table, {pr_url, updated})
        Logger.info("Merge approved: pr=#{pr_url} approver=#{approver}")
        {:reply, {:ok, :approved}, state}
      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:approve_by_key, key, approver, identity}, _from, state) do
    # Find the entry with matching run_id in the value's requested_by field
    case :ets.tab2list(@table) |> Enum.find(fn {_url, req} -> req.requested_by == key end) do
      {pr_url, req} ->
        updated = %{req | status: :approved, approver: approver, approver_identity: identity, approved_at: System.system_time(:millisecond)}
        :ets.insert(@table, {pr_url, updated})
        Logger.info("Merge approved by key: key=#{key} pr=#{pr_url} approver=#{approver}")
        {:reply, {:ok, :approved}, state}
      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end
end
