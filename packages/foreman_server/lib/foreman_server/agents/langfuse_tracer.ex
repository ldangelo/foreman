defmodule ForemanServer.Agents.LangfuseTracer do
  @moduledoc "Langfuse tracing for LLM calls. TRD-2026-4212be7e / LGL-T002 / TRD-043."

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
      metadata: Keyword.get(opts, :metadata, %{})
    }

    {:ok, trace}
  end
end
