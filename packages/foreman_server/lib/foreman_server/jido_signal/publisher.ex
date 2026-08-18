defmodule ForemanServer.JidoSignal.Publisher do
  @moduledoc """
  Publisher for Foreman Jido signals.

  Provides functions for publishing signals to the jido_signal bus.
  """

  require Logger

  alias ForemanServer.JidoSignal.AgentDirective

  @doc """
  Publishes an agent directive signal.

  ## Parameters
  - `task_id`: The task ID
  - `phase`: The phase (e.g., "review", "implement")
  - `directive`: The directive text
  - `data`: Optional additional data

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec publish_agent_directive(String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def publish_agent_directive(task_id, phase, directive, data \\ %{}) do
    case AgentDirective.new(task_id, phase, directive, data) do
      {:ok, signal} ->
        topic = "agents/#{task_id}/directive"
        Jido.Signal.Bus.publish(:foreman_signal_bus, [signal])
        Logger.debug("Published agent directive signal to #{topic}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to create agent directive signal: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
