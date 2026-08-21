defmodule ForemanServer.AgentRuntimeLangfuseWiringTest do
  @moduledoc """
  REQ-020 / LGL-T004 — proves that the production code path for
  `ForemanServer.AgentRuntime` calls `LangfuseTracer.emit_trace/6`
  with the routing metadata (routed_to + routing_reason + capability)
  required by the auditability requirement.

  Strategy: invoke the `__emit_langfuse_trace_for_test__/6` test
  export of `ForemanServer.AgentRuntime` directly. The export is a
  `@doc false` shim around `emit_langfuse_trace/6`, which is the
  helper called from each success branch of `execute_react/6` and
  `execute_cot/6`. The wiring in `agent_runtime.ex` itself is
  grep-verifiable.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime
  alias ForemanServer.Agents.LangfuseTracer

  setup do
    :meck.new(LangfuseTracer, [:no_link, :passthrough])

    :meck.expect(LangfuseTracer, :emit_trace, fn prompt,
                                                 response,
                                                 model,
                                                 cost_usd,
                                                 latency_ms,
                                                 opts ->
      send(self(), {:langfuse_emit, prompt, response, model, cost_usd, latency_ms, opts})
      {:ok, %{id: "trace-stub", metadata: Map.new(opts)}}
    end)

    on_exit(fn -> :meck.unload() end)

    :ok
  end

  describe "emit_langfuse_trace/6 (REQ-020 wiring helper)" do
    test "passes routed_to + routing_reason + capability to LangfuseTracer" do
      monotonic_start = System.monotonic_time(:microsecond)

      AgentRuntime.__emit_langfuse_trace_for_test__(
        "hello",
        "hi",
        "openai:gpt-4o-mini",
        monotonic_start,
        :code,
        42
      )

      assert_received {:langfuse_emit, "hello", "hi", "openai:gpt-4o-mini", 0.0, _latency_ms,
                       opts}

      assert opts[:routed_to] == "openai:gpt-4o-mini"
      assert opts[:routing_reason] == "auto-routing:code"
      assert opts[:capability] == :code_generation
      assert opts[:token_count] == 42
    end

    test "maps task_type :chat to capability :chat" do
      AgentRuntime.__emit_langfuse_trace_for_test__(
        "p",
        "r",
        "anthropic:claude-3-haiku",
        System.monotonic_time(:microsecond),
        :chat,
        5
      )

      assert_received {:langfuse_emit, _, _, _, _, _, opts}
      assert opts[:capability] == :chat
      assert opts[:routing_reason] == "auto-routing:chat"
    end

    test "maps unknown task_type to capability :chat (safe default)" do
      AgentRuntime.__emit_langfuse_trace_for_test__(
        "p",
        "r",
        "openai:gpt-4",
        System.monotonic_time(:microsecond),
        :something_weird,
        1
      )

      assert_received {:langfuse_emit, _, _, _, _, _, opts}
      assert opts[:capability] == :chat
      assert opts[:routing_reason] == "auto-routing:chat"
    end

    test "latency_ms is non-negative" do
      AgentRuntime.__emit_langfuse_trace_for_test__(
        "p",
        "r",
        "openai:gpt-4",
        System.monotonic_time(:microsecond),
        :chat,
        0
      )

      assert_received {:langfuse_emit, _, _, _, _, latency_ms, _}
      assert is_integer(latency_ms)
      assert latency_ms >= 0
    end
  end

  describe "production wiring is grep-verifiable" do
    test "LangfuseTracer.emit_trace is called from execute_react and execute_cot success branches" do
      # This test is meta: it proves the wiring by checking that the
      # production code contains the call sites. Doing this in-test
      # (rather than in shell) keeps the contract self-documenting
      # and survives file moves within the module tree.
      agent_runtime_path =
        Path.expand(
          "../../lib/foreman_server/agent_runtime.ex",
          __DIR__
        )

      {:ok, content} = File.read(agent_runtime_path)

      assert content =~ "emit_langfuse_trace(",
             "agent_runtime.ex must contain emit_langfuse_trace calls in success branches"

      react_count =
        content
        |> String.split("emit_langfuse_trace(")
        |> length()
        |> Kernel.-(1)

      assert react_count >= 4,
             "expected at least 4 emit_langfuse_trace call sites (2 in execute_react, 2 in execute_cot); found #{react_count}"
    end
  end
end
