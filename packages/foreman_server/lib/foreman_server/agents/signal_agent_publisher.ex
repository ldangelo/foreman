defmodule ForemanServer.Agents.SignalAgentPublisher do
  @moduledoc """
  Foreman wrapper that publishes Agent↔Agent signals on the
  `agents.<phase>.directive` topic (TRD-2026-4212be7e, JSI-T002).

  Per the TRD:
    "Implement Agent→Agent signal pub/sub via Bus.publish to
     agents/<phase> topic."

  The Jido-aligned form (Jido's path grammar rejects `/`) is
  `agents.<phase>.directive`. The publisher wraps
  `Jido.Signal.Bus.publish/2` so Foreman code can dispatch an
  agent-to-agent signal with a stable, well-typed call.

  ## Bus resolution

  Like `SignalDirectivePublisher`, this module accepts a registered
  bus name, a pid, or the `:default` sentinel that resolves to
  the supervised `:foreman_jido_signal_bus`.
  """

  alias Jido.Signal.Bus

  @doc """
  Sentinel for the production bus name (`:foreman_jido_signal_bus`).
  """
  @spec default_bus_token() :: :default
  def default_bus_token, do: :default

  @doc """
  Publish a signal addressed to all agents in `phase` (the TRD
  phrasing — the agent phase is the routing key, not an agent id).

  Returns the standard `Jido.Signal.Bus.publish/2` result.
  """
  @spec publish(GenServer.server() | :default, String.t(), map()) ::
          {:ok, [Jido.Signal.Bus.RecordedSignal.t()]} | {:error, term()}
  def publish(bus, phase, payload) when is_binary(phase) and is_map(payload) do
    bus = resolve_bus(bus)
    topic = "agents.#{phase}.directive"

    {:ok, signal} =
      Jido.Signal.new(topic, payload, source: "foreman.signal_agent_publisher")

    Bus.publish(bus, [signal])
  end

  defp resolve_bus(:default), do: :foreman_jido_signal_bus
  defp resolve_bus(other), do: other
end
