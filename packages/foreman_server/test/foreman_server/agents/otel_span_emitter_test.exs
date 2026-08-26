defmodule ForemanServer.Agents.OtelSpanEmitterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.OtelSpanEmitter

  @moduletag :otel

  test "emit_cmd_span/3 returns :ok and accepts cmd attributes" do
    assert :ok == OtelSpanEmitter.emit_cmd_span("agent-001", "MyApp.Actions.Greet", 1_234)
  end

  test "emit_llm_span/4 returns :ok and accepts LLM attributes" do
    assert :ok ==
             OtelSpanEmitter.emit_llm_span(
               "gpt-4o-mini",
               512,
               0.0023,
               "capability.text.generation"
             )
  end

  test "emit_signal_span/3 returns :ok and accepts signal attributes" do
    assert :ok ==
             OtelSpanEmitter.emit_signal_span(
               "Jido.Signal.Run.Completed",
               "agents.build.directive",
               "delivered"
             )
  end

  test "emit_cmd_span/3 guards on bad input" do
    assert_raise FunctionClauseError, fn ->
      OtelSpanEmitter.emit_cmd_span(:not_a_binary, "action", 100)
    end
  end
end
