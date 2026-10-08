defmodule ForemanServer.Jobsite.Control do
  @moduledoc """
  ETS-backed pause/cancel intent table for running jobsites, mirroring
  `ForemanServer.RunControl`'s shape: `Jobsite.Executor` blocks synchronously
  on an in-flight iteration's agent, so an external `Jobsite.pause/2` or
  `Jobsite.cancel/2` call reaches it through this table rather than a
  `GenServer.call` the executor has no chance to answer until it next polls.

  `Jobsite.Executor` polls `intent/1` between iterations and passes an
  `intent_fun` through to `Jobsite.AgentRunner.run/4`, which polls it via a
  periodic self-tick so a pause/cancel also interrupts an iteration already
  in flight, not only the gap between iterations.
  """

  @table __MODULE__

  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @spec request(String.t(), {:pause, String.t()} | {:cancel, String.t()}) :: :ok
  def request(jobsite_id, intent) do
    ensure_table()
    :ets.insert(@table, {jobsite_id, intent})
    :ok
  end

  @spec intent(String.t()) :: {:pause, String.t()} | {:cancel, String.t()} | :none
  def intent(jobsite_id) do
    ensure_table()

    case :ets.lookup(@table, jobsite_id) do
      [{^jobsite_id, intent}] -> intent
      [] -> :none
    end
  end

  @spec clear(String.t()) :: :ok
  def clear(jobsite_id) do
    ensure_table()
    :ets.delete(@table, jobsite_id)
    :ok
  end
end
