defmodule ForemanServer.AgentRuntimeJidoAiTest do
  @moduledoc """
  `AgentRuntime.execute/3` with `strategy: :react | :cot`, driven through the real
  `JidoAiRunner` with the LLM faked at the `req_llm` boundary. Pins what the
  LiteLLM/chat routing path reports: a runner error is an error outcome and
  never a success trace, and the Langfuse cost is the provider's number or nil,
  never a literal 0.0.
  """

  # :meck replaces ReqLLM.Generation / LangfuseTracer globally.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.AgentRuntime
  alias ForemanServer.Agents.LangfuseTracer
  alias ForemanServer.Test.FakeReqLlm
  alias ForemanServer.TelemetryTest.Handler

  @model "openai:fake-model"
  @usage %{input_tokens: 11, output_tokens: 7, total_tokens: 18}
  @completion [:foreman, :agent_runtime, :invocation, :complete]
  @execute_stop [:foreman, :agent_runtime, :execute, :stop]

  setup do
    test_pid = self()

    :ok = :meck.new(LangfuseTracer, [:no_link, :passthrough])

    :meck.expect(LangfuseTracer, :emit_trace, fn prompt, response, model, cost, _latency, opts ->
      send(test_pid, {:langfuse_trace, prompt, response, model, cost, opts})
      {:ok, %{id: "trace-stub"}}
    end)

    {handler_id, ref} = Handler.attach_event_handlers(test_pid, [@completion, @execute_stop])

    on_exit(fn ->
      :telemetry.detach(handler_id)
      :meck.unload(LangfuseTracer)
    end)

    {:ok, ref: ref}
  end

  for strategy <- [:react, :cot] do
    describe "strategy #{inspect(strategy)}" do
      test "success returns the model text and traces the provider's real cost and tokens",
           %{ref: ref} do
        FakeReqLlm.install(self(), {:answer, "the answer", Map.put(@usage, :total_cost, 0.25)})

        assert {:ok, "the answer"} = run(unquote(strategy))

        assert_receive {:langfuse_trace, "prompt", "the answer", @model, 0.25, opts}
        assert opts[:token_count] == 18
        assert_receive {@completion, ^ref, _measurements, %{status: :ok}}
        refute_receive {@completion, ^ref, _, _}, 50
      end

      test "cost is nil in the Langfuse payload when the provider reports none" do
        FakeReqLlm.install(self(), {:answer, "the answer", @usage})

        assert {:ok, "the answer"} = run(unquote(strategy))

        assert_receive {:langfuse_trace, "prompt", "the answer", @model, cost, opts}
        assert cost == nil
        assert opts[:token_count] == 18
      end

      test "usage the provider did not report is an unknown token count, not zero" do
        FakeReqLlm.install(self(), {:answer_without_usage, "the answer"})

        assert {:ok, "the answer"} = run(unquote(strategy))

        assert_receive {:langfuse_trace, "prompt", "the answer", @model, nil, opts}
        assert opts[:token_count] == nil
      end

      test "a runner error is an error outcome: one completion event, no success trace",
           %{ref: ref} do
        FakeReqLlm.install(self(), {:error, :econnrefused})

        assert {:escalate, %{kind: :llm_failed, context: context}} = run(unquote(strategy))
        assert context.code == :strategy_failed

        assert_receive {@execute_stop, ^ref, _, %{strategy: unquote(strategy)}}
        assert_receive {@completion, ^ref, _measurements, %{status: :adapter_error}}
        refute_receive {@completion, ^ref, _, _}, 50
        refute_received {:langfuse_trace, _, _, _, _, _}
      end
    end
  end

  describe "default model (no :model option)" do
    for strategy <- [:react, :cot] do
      test "#{strategy} resolves the :fast alias and records its string label" do
        FakeReqLlm.install(self(), {:answer, "the answer", @usage})

        assert {:ok, "the answer"} =
                 AgentRuntime.execute("prompt", %{},
                   strategy: unquote(strategy),
                   task_type: :chat,
                   timeout_ms: 7_000
                 )

        label = Jido.AI.model_label(:fast)
        assert is_binary(label)
        assert_receive {:langfuse_trace, "prompt", "the answer", ^label, _cost, _opts}

        # The runtime's token cap and the caller's timeout reach the provider call.
        assert_received {:fake_llm_call, _model, _messages, provider_opts}
        assert provider_opts[:max_tokens] == 4096
        assert provider_opts[:receive_timeout] == 7_000
      end

      test "#{strategy} with an unresolvable model alias is a typed error, not an exception",
           %{ref: ref} do
        FakeReqLlm.install(self(), {:answer, "unused", @usage})

        assert {:escalate, %{kind: :llm_error, context: %{code: :invalid_model}}} =
                 AgentRuntime.execute("prompt", %{},
                   strategy: unquote(strategy),
                   model: :no_such_alias,
                   task_type: :chat
                 )

        assert_receive {@completion, ^ref, _measurements, %{status: :adapter_error}}
        refute_received {:fake_llm_call, _, _, _}
      end
    end
  end

  defp run(strategy) do
    AgentRuntime.execute("prompt", %{}, strategy: strategy, model: @model, task_type: :chat)
  end
end
