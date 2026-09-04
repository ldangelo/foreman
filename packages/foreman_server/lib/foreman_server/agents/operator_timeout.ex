defmodule ForemanServer.Agents.OperatorTimeout do
  @moduledoc """
  Per-workflow operator timeout manager.

  Schedules a timer when an operator question is dispatched; on expiry,
  logs a warning. The previously-registered task.block handler is removed.

  TRD-2026-4212be7e / JSI-T009 / TRD-027.
  """
  use GenServer
  require Logger

  @table :operator_timeout_registry
  @default_timeout_ms 5 * 60 * 1000  # 5 minutes

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, %{timers: %{}}}
  end

  def schedule(workflow_id, task_id, timeout_ms \\ @default_timeout_ms) do
    GenServer.call(__MODULE__, {:schedule, workflow_id, task_id, timeout_ms})
  end

  def cancel(workflow_id, task_id) do
    GenServer.call(__MODULE__, {:cancel, workflow_id, task_id})
  end

  @impl true
  def handle_call({:schedule, workflow_id, task_id, timeout_ms}, _from, state) do
    ref = :timer.send_after(timeout_ms, self(), {:expire, workflow_id, task_id})
    :ets.insert(@table, {{workflow_id, task_id}, ref})
    {:reply, :ok, state}
  end

  def handle_call({:cancel, workflow_id, task_id}, _from, state) do
    case :ets.lookup(@table, {workflow_id, task_id}) do
      [{_, ref}] ->
        :timer.cancel(ref)
        :ets.delete(@table, {workflow_id, task_id})
        {:reply, :ok, state}
      [] ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({:expire, workflow_id, task_id}, state) do
    :ets.delete(@table, {workflow_id, task_id})
    Logger.warning("Operator timeout for workflow=#{workflow_id} task=#{task_id}; task.block handler removed, no-op")

    {:noreply, state}
  end
end
