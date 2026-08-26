defmodule ForemanServer.Agents.OtelSpanEmitter do
  @moduledoc """
  Emits OTEL spans for Jido.Agent `cmd/2`, LLM calls, and signal dispatch.

  TRD-2026-4212be7e / JOT-T002 (TRD-060), JOT-T003 (TRD-061), JOT-T004 (TRD-062).
  Backed by `jido_otel` (TRD-059) for tracer configuration.

  Each emit function is a leaf call (no callable block) suitable for
  instrumentation call sites that have already measured `duration_us` or
  have the LLM/signal attributes in hand.
  """

  require OpenTelemetry.Tracer

  @doc """
  Emit a `jido.cmd` span capturing the agent id, action name, and duration
  in microseconds. Called from the Jido `cmd/2` instrumentation hook.
  """
  @spec emit_cmd_span(String.t(), String.t(), non_neg_integer()) :: :ok
  def emit_cmd_span(agent_id, action_name, duration_us)
      when is_binary(agent_id) and is_binary(action_name) and is_integer(duration_us) do
    OpenTelemetry.Tracer.with_span(
      "jido.cmd",
      %{attributes: %{
        "jido.agent_id" => agent_id,
        "jido.action" => action_name,
        "duration_us" => duration_us
      }}
    ) do
      :ok
    end
  end

  @doc """
  Emit a `jido.llm` span capturing the model, token counts, cost, and routing
  reason. Called from the LiteLLM/Langfuse call site (TRD-061).
  """
  @spec emit_llm_span(String.t(), non_neg_integer(), number(), String.t()) :: :ok
  def emit_llm_span(model, token_count, cost_usd, routing_reason)
      when is_binary(model) and is_integer(token_count) and is_binary(routing_reason) do
    OpenTelemetry.Tracer.with_span(
      "jido.llm",
      %{attributes: %{
        "llm.model" => model,
        "llm.tokens" => token_count,
        "llm.cost_usd" => cost_usd,
        "llm.routing_reason" => routing_reason
      }}
    ) do
      :ok
    end
  end

  @doc """
  Emit a `jido.signal` span capturing the signal type, topic, and delivery
  status. Called from signal publish/dispatch instrumentation (TRD-062).
  """
  @spec emit_signal_span(String.t(), String.t(), String.t()) :: :ok
  def emit_signal_span(signal_type, topic, delivery_status)
      when is_binary(signal_type) and is_binary(topic) and is_binary(delivery_status) do
    OpenTelemetry.Tracer.with_span(
      "jido.signal",
      %{attributes: %{
        "signal.type" => signal_type,
        "signal.topic" => topic,
        "signal.delivery_status" => delivery_status
      }}
    ) do
      :ok
    end
  end
end
