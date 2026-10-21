defmodule ForemanServer.Agents.OtelSpanCostTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.{LangfuseTracer, OtelSpanEmitter}

  test "a provider-reported cost is on the span; an unknown cost leaves the key absent" do
    with_cost = OtelSpanEmitter.llm_span_attributes("m", 10, 0.25, "auto")
    assert with_cost["llm.cost_usd"] == 0.25
    assert with_cost["llm.tokens"] == 10

    unknown = OtelSpanEmitter.llm_span_attributes("m", 10, nil, "auto")
    refute Map.has_key?(unknown, "llm.cost_usd")
    assert unknown["llm.tokens"] == 10
  end

  test "a real zero cost is kept, unknown tokens are omitted" do
    free = OtelSpanEmitter.llm_span_attributes("m", nil, +0.0, "auto")
    assert free["llm.cost_usd"] == 0.0
    refute Map.has_key?(free, "llm.tokens")
  end

  test "the Langfuse trace carries nil cost, never a fabricated 0.0" do
    assert {:ok, trace} = LangfuseTracer.emit_trace("p", "r", "m", nil, 5)
    assert trace.cost_usd == nil
  end
end
