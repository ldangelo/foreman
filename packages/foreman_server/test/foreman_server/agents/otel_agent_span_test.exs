defmodule ForemanServer.Agents.OtelAgentSpanTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.OtelSpanEmitter

  describe "with_agent_span/3" do
    test "returns the wrapped function's result unchanged, errors included" do
      assert {:ok, :done} == OtelSpanEmitter.with_agent_span("t.ok", %{}, fn -> {:ok, :done} end)

      assert {:error, :boom} ==
               OtelSpanEmitter.with_agent_span("t.err", %{}, fn -> {:error, :boom} end)

      assert {:error, :a, :b} ==
               OtelSpanEmitter.with_agent_span("t.err3", %{}, fn -> {:error, :a, :b} end)

      assert :plain == OtelSpanEmitter.with_agent_span("t.plain", %{}, fn -> :plain end)
    end

    test "an exception inside the function propagates; the span never swallows it" do
      assert_raise RuntimeError, "boom", fn ->
        OtelSpanEmitter.with_agent_span("t.raise", %{}, fn -> raise "boom" end)
      end
    end
  end

  test "every span's attribute map names the agent, and the cost-less map stays minimal" do
    attrs = OtelSpanEmitter.llm_span_attributes("m", nil, nil, "auto")

    assert attrs["gen_ai.agent.name"] == "foreman"
    refute Map.has_key?(attrs, "llm.tokens")
    refute Map.has_key?(attrs, "llm.cost_usd")
  end
end
