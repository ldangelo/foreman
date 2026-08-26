defmodule ForemanServer.Agents.LangfuseTracerTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.LangfuseTracer

  test "emit_trace returns trace with required fields" do
    assert {:ok, trace} = LangfuseTracer.emit_trace("hi", "hello", "gpt-4", 0.003, 250)
    assert trace.prompt == "hi"
    assert trace.response == "hello"
    assert trace.model == "gpt-4"
    assert trace.cost_usd == 0.003
    assert trace.latency_ms == 250
  end
end

defmodule ForemanServer.Agents.LangfuseTracerRoutingTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.LangfuseTracer

  test "emit_trace includes routing metadata" do
    assert {:ok, trace} =
             LangfuseTracer.emit_trace("hi", "hello", "gpt-4", 0.003, 250,
               routed_to: "gpt-4o",
               routing_reason: "cost"
             )

    assert trace.metadata.routed_to == "gpt-4o"
    assert trace.metadata.routing_reason == "cost"
  end

  test "emit_routing_metadata standalone" do
    assert {:ok, m} = LangfuseTracer.emit_routing_metadata("claude-3", "capability:code")
    assert m.routed_to == "claude-3"
    assert m.routing_reason == "capability:code"
  end
end
