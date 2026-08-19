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

  def pending do
    :ets.tab2list(@table) |> Enum.map(fn {url, _} -> url end)
  end

  @impl true
  def handle_call({:request, pr_url, requested_by}, _from, state) do
    Logger.info("Merge approval requested: pr=#{pr_url} by=#{requested_by}")
    :ets.insert(@table, {pr_url, %{status: :pending, requested_by: requested_by, approver: nil, approver_identity: nil, requested_at: System.system_time(:millisecond), approved_at: nil}})
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
end
