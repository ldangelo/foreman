defmodule ForemanServer.Agents.SignalDirectivePublisher do
  @moduledoc """
  Foreman-side publisher that emits a directive to a Jido agent via
  the `agents.<agent-id>.directive` topic pattern
  (TRD-2026-4212be7e, JSI-T011).

  The publisher wraps `Jido.Signal.Bus.publish/2` so Foreman code
  can dispatch a directive with a stable, well-typed call instead of
  building `Jido.Signal` structs by hand at every call site.

  ## Public API

    - `publish/3` — bus (or `:default`), agent_id, payload. Returns
      the standard `Jido.Signal.Bus.publish/2` result.

  ## Topic pattern

  The topic used is exactly `JidoSignalTopics.agent_directive(agent_id)`,
  which is `agents.<id>.directive` — the Jido-aligned form (Jido's
  path grammar rejects the TRD's slash-separated
  `agents/<agent-id>/directive`). The single source of truth for
  the topic name is `ForemanServer.Agents.JidoSignalTopics`.

  ## Bus resolution

  The publisher accepts the bus as either a registered name (atom) or
  a pid. In production, callers can pass `:default` to resolve to
  the supervised `foreman_jido_signal_bus` process (the name used
  by `ForemanServer.Application.maybe_signal_to_command_child/0`).

  ## Directive queue integration

  When `ForemanServer.Agents.DirectiveQueue` is running, every
  marked `:dispatched` after successful publish. This feeds the
  LiveDashboard directive-queue view (TRD-056 / JLD-T002).
  """

  alias ForemanServer.Agents.JidoSignalTopics
  alias ForemanServer.Agents.DirectiveQueue
  alias ForemanServer.Agents.OtelSpanEmitter
  alias Jido.Signal.Bus
  @doc """
  Sentinel value for `bus` that resolves to the supervised
  `foreman_jido_signal_bus` process.
  """
  @spec default_bus_token() :: :default
  def default_bus_token, do: :default

  @doc """
  The name of the production bus that the application supervises
  via `maybe_signal_to_command_child/0`.
  """
  @spec production_bus_name() :: atom()
  def production_bus_name, do: :foreman_jido_signal_bus

  @doc """
  Publish a directive to a specific agent.

  ## Arguments

    - `bus` — the bus to publish on. Pass either a registered name
      (atom), a pid, or `:default` to use the supervised
      `:foreman_jido_signal_bus`.
    - `agent_id` — the destination Jido agent id.
    - `payload` — the directive body. Must be a map; it is stored
      in the `Jido.Signal.data` field and consumed by the agent's
      directive subscriber.

  ## Returns

  The standard `Jido.Signal.Bus.publish/2` result:
  `{:ok, [recorded_signal]}` on success, or `{:error, reason}`.
  """
  @spec publish(GenServer.server() | :default, String.t(), map()) ::
          {:ok, [Jido.Signal.Bus.RecordedSignal.t()]} | {:error, term()}
  def publish(bus, agent_id, payload) when is_binary(agent_id) and is_map(payload) do
    bus = resolve_bus(bus)
    topic = JidoSignalTopics.agent_directive(agent_id)

    {:ok, signal} =
      Jido.Signal.new(topic, payload,
        source: "foreman.signal_directive_publisher"
      )

    # Record in directive queue before publishing (TRD-056 / JLD-T002).
    # If the queue is not running, enqueue/2 returns :error and we
    # proceed anyway — the queue is optional diagnostic instrumentation.
    _ = record_in_queue(agent_id, payload)

    result = Bus.publish(bus, [signal])

    # JOT-T004: emit jido.signal span for directive dispatch.
    delivery_status =
      case result do
        {:ok, _} -> "delivered"
        {:error, _} -> "failed"
      end

    _ = OtelSpanEmitter.emit_signal_span("agent.directive", topic, delivery_status)

    # Mark dispatched on success. On failure we leave the entry in
    # :pending so operators can see it stalled.
    with {:ok, [recorded | _]} <- result do
      :ok = DirectiveQueue.dispatched(recording_id(recorded))
    end

    result
  end

  defp resolve_bus(:default), do: production_bus_name()
  defp resolve_bus(other), do: other

  # Record the directive in the queue. Silently ignores if the
  # DirectiveQueue GenServer is not running.
  defp record_in_queue(agent_id, payload) do
    DirectiveQueue.enqueue(agent_id, payload)
  rescue
    _ ->
      :ok
  end

  defp recording_id(%Jido.Signal.Bus.RecordedSignal{id: id}), do: id
  defp recording_id(other), do: inspect(other)
end
