defmodule ForemanServer.Agents.LangfuseTracer do
  @moduledoc "Langfuse tracing with routing auditability. TRD-2026-4212be7e / LGL-T002 + LGL-T004."

  def endpoint, do: Application.get_env(:langfuse, :endpoint, "http://localhost:3000")

  def emit_trace(prompt, response, model, cost_usd, latency_ms, opts \\ []) do
    trace = %{
      id: "trace-#{System.unique_integer([:positive])}",
      timestamp: System.system_time(:millisecond),
      prompt: prompt,
      response: response,
      model: model,
      cost_usd: cost_usd,
      latency_ms: latency_ms,
      metadata: %{
        routed_to: Keyword.get(opts, :routed_to, model),
        routing_reason: Keyword.get(opts, :routing_reason, "auto-routing"),
        capability: Keyword.get(opts, :capability, :chat)
      }
    }

    {:ok, trace}
  end

  def emit_routing_metadata(routed_to, reason, opts \\ []) do
    metadata = %{
      routed_to: routed_to,
      routing_reason: reason,
      capability: Keyword.get(opts, :capability, :chat),
      timestamp: System.system_time(:millisecond)
    }

    {:ok, metadata}
  end
end
