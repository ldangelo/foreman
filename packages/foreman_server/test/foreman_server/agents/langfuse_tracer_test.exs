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
