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

  describe "with_agent_span/4 annotate" do
    test "receives the result, and the result still comes back unchanged" do
      test_pid = self()

      annotate = fn result ->
        send(test_pid, {:annotated, result})
        %{"gen_ai.usage.output_tokens" => 3}
      end

      assert {:ok, :done} ==
               OtelSpanEmitter.with_agent_span("t.annot", %{}, fn -> {:ok, :done} end, annotate)

      assert_received {:annotated, {:ok, :done}}
    end
  end

  describe "message_json/2" do
    test "is the JSON list of role/content that GenAI viewers read" do
      assert [%{"role" => "user", "content" => "hi"}] ==
               "user" |> OtelSpanEmitter.message_json("hi") |> Jason.decode!()
    end

    test "truncates long text with a marker instead of exporting it whole" do
      [%{"content" => content}] =
        "assistant"
        |> OtelSpanEmitter.message_json(String.duplicate("x", 20_000))
        |> Jason.decode!()

      assert String.length(content) < 8_100
      assert String.ends_with?(content, "[truncated]")
    end
  end

  describe "usage_attributes/1" do
    test "reports counts, leaves absent ones out rather than zero-filling" do
      usage = %ForemanServer.Usage{input_tokens: 12, output_tokens: nil}

      assert %{"gen_ai.usage.input_tokens" => 12} == OtelSpanEmitter.usage_attributes(usage)
      assert %{} == OtelSpanEmitter.usage_attributes(nil)
    end

    test "never raises on a malformed usage: it runs inside the traced turn" do
      assert %{} == OtelSpanEmitter.usage_attributes(%{input_tokens: 5})
    end
  end

  test "every span's attribute map names the agent, and the cost-less map stays minimal" do
    attrs = OtelSpanEmitter.llm_span_attributes("m", nil, nil, "auto")

    assert attrs["gen_ai.agent.name"] == "foreman"
    refute Map.has_key?(attrs, "llm.tokens")
    refute Map.has_key?(attrs, "llm.cost_usd")
  end
end
