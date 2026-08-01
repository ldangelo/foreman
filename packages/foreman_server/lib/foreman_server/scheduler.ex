defmodule ForemanServer.Scheduler do
  @moduledoc """
  Public scheduler API backed by the single `ForemanServer.Scheduler.Runtime`
  process.
  """

  alias ForemanServer.Scheduler.Runtime

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: Runtime.start_link(opts)

  @spec tick(keyword()) :: {:ok, map()} | {:error, term()}
  def tick(opts \\ []), do: Runtime.tick(opts)

  @spec state() :: map()
  def state, do: Runtime.state()

  @spec handle_event(map()) :: :ok
  def handle_event(event), do: Runtime.handle_event(event)

  @spec record_intent(map(), map()) :: {:ok, map()} | {:error, term()}
  def record_intent(task, attrs), do: Runtime.record_intent(task, attrs)

  @spec confirm_execution(map()) :: {:ok, map()} | {:error, term()}
  def confirm_execution(attrs), do: Runtime.confirm_execution(attrs)
end
