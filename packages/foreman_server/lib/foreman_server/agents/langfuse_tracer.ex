defmodule ForemanServer.Agents.LangfuseTracer do
  @moduledoc "Langfuse tracing with routing auditability. TRD-2026-4212be7e / LGL-T002 + LGL-T004."

  def endpoint,
    do: Application.get_env(:foreman_server, :langfuse)[:endpoint] || "http://localhost:3000"

  @doc """
  Build a trace payload. `cost_usd` is `nil` when the provider reported no
  cost (unknown, not free).
  """
  @spec emit_trace(String.t(), term(), String.t(), number() | nil, non_neg_integer(), keyword()) ::
          {:ok, map()}
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
