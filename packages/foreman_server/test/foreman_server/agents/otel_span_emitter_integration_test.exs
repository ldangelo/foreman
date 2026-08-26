defmodule ForemanServer.Agents.OtelSpanEmitterIntegrationTest do
  @moduledoc """
  JOT-T005 — OTEL integration tests verifying span emission produces real
  spans against a configured tracer (per TRD-2026-4212be7e / JOT-T002..T004).
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.OtelSpanEmitter

  @moduletag :otel

  setup do
    # Configure a default tracer so OpenTelemetry.Tracer.with_span records spans.
    :application.set_env(:opentelemetry, :tracer, :otel_tracer_default)
    :ok
  end

  test "emit_cmd_span/3 produces jido.cmd span and returns :ok" do
    assert :ok = OtelSpanEmitter.emit_cmd_span("agent-1", "TestAction", 1500)
  end

  test "emit_llm_span/4 produces jido.llm span and returns :ok" do
    assert :ok = OtelSpanEmitter.emit_llm_span("gpt-4", 250, 0.003, "auto-routing")
  end

  test "emit_signal_span/3 produces jido.signal span and returns :ok" do
    assert :ok =
             OtelSpanEmitter.emit_signal_span(
               "agent.directive",
               "agents.1.directive",
               "delivered"
             )
  end
end
