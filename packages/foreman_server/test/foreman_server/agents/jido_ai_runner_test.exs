defmodule ForemanServer.Agents.JidoAiRunnerTest do
  @moduledoc """
  `ForemanServer.Agents.JidoAiRunner` against the real `jido_ai` ReAct runtime
  and CoT call, with the LLM faked at the `req_llm` boundary
  (`ForemanServer.Test.FakeReqLlm`). No network, no placeholder: the tests fail
  if the strategy does not actually execute.
  """

  # :meck replaces ReqLLM.Generation / ReAct globally.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Agents.JidoAiRunner
  alias ForemanServer.Agents.JidoAiRunner.{Error, Result}
  alias ForemanServer.Test.FakeReqLlm
  alias Jido.AI.Reasoning.{ChainOfThought, ReAct}

  @usage %{input_tokens: 11, output_tokens: 7, total_tokens: 18}

  describe "react" do
    test "returns the model's text, termination reason and usage from a real ReAct run" do
      FakeReqLlm.install(self(), {:answer, "four", Map.put(@usage, :total_cost, 0.25)})

      assert {:ok, %Result{} = result} = JidoAiRunner.run(:react, "What is 2 + 2?")

      assert result.strategy == :react
      assert result.output == "four"
      assert result.termination_reason == :final_answer
      assert %{input_tokens: 11, output_tokens: 7, total_tokens: 18} = result.usage
      assert result.usage.total_cost == 0.25
      assert is_list(result.trace) and result.trace != []
      assert_received {:fake_llm_call, _model, _messages, _opts}
    end

    test "usage is nil, not an empty or zeroed map, when the provider reports none" do
      FakeReqLlm.install(self(), {:answer_without_usage, "four"})

      assert {:ok, %Result{output: "four", usage: nil}} = JidoAiRunner.run(:react, "2 + 2?")
    end

    test "a failing model is a typed :strategy_failed error carrying the cause" do
      FakeReqLlm.install(self(), {:error, :econnrefused})

      assert {:error, %Error{code: :strategy_failed, details: details}} =
               JidoAiRunner.run(:react, "2 + 2?")

      assert details != nil
    end

    test "documented non-answer terminations are :strategy_failed, never success" do
      mock_react()

      for reason <- [:cancelled, :max_iterations] do
        stub_react_run(%{
          result: "Maximum iterations reached without a final answer.",
          termination_reason: reason,
          usage: %{},
          final_token: nil,
          trace: []
        })

        assert {:error, %Error{code: :strategy_failed}} = JidoAiRunner.run(:react, "q"),
               "termination_reason #{inspect(reason)} must not be reported as success"
      end
    end

    test "an unrecognised ReAct result shape is :unexpected_result_shape carrying the raw value" do
      mock_react()

      for odd <- [
            %{result: 42, termination_reason: :final_answer, usage: %{}},
            %{result: "text", termination_reason: nil, usage: %{}},
            %{result: "text", termination_reason: :something_new, usage: %{}},
            %{unrelated: true}
          ] do
        stub_react_run(odd)

        assert {:error, %Error{code: :unexpected_result_shape, details: ^odd}} =
                 JidoAiRunner.run(:react, "q")
      end
    end

    test "a genuine crash inside the strategy surfaces instead of becoming a value" do
      mock_react()
      :meck.expect(ReAct, :run, fn _prompt, _config, _opts -> raise "boom" end)

      assert_raise RuntimeError, "boom", fn -> JidoAiRunner.run(:react, "q") end
    end
  end

  describe "cot" do
    test "makes a real model call with the CoT system prompt and returns its text and usage" do
      FakeReqLlm.install(self(), {:answer, "Step 1: add.\nAnswer: 4", @usage})

      assert {:ok, %Result{} = result} = JidoAiRunner.run(:cot, "What is 2 + 2?")

      assert result.strategy == :cot
      assert result.output == "Step 1: add.\nAnswer: 4"
      assert result.termination_reason == :final_answer
      assert %{total_tokens: 18} = result.usage
      assert result.trace == nil

      assert_received {:fake_llm_call, _model, messages, _opts}

      assert Enum.any?(messages, fn message ->
               message.role == :system and
                 Jido.AI.Turn.extract_text(message.content) =~ "step by step"
             end)
    end

    test "a failing model is a typed :strategy_failed error" do
      FakeReqLlm.install(self(), {:error, :timeout})

      assert {:error, %Error{code: :strategy_failed, details: :timeout}} =
               JidoAiRunner.run(:cot, "q")
    end

    test "an empty model reply is :unexpected_result_shape, not an empty success" do
      FakeReqLlm.install(self(), {:answer_without_usage, ""})

      assert {:error, %Error{code: :unexpected_result_shape}} = JidoAiRunner.run(:cot, "q")
    end

    test "usage is nil when the provider reports none" do
      FakeReqLlm.install(self(), {:answer_without_usage, "Answer: 4"})

      assert {:ok, %Result{usage: nil}} = JidoAiRunner.run(:cot, "q")
    end
  end

  test "an unknown strategy is a typed :unknown_strategy error and never reaches the model" do
    FakeReqLlm.install(self(), {:answer, "unused", @usage})

    assert {:error, %Error{code: :unknown_strategy}} = JidoAiRunner.run(:bogus, "test prompt")
    refute_received {:fake_llm_call, _, _, _}
  end

  # Third-party contract pin (AGENTS 5.6). JidoAiRunner pattern-matches these
  # exact shapes; a jido_ai bump that changes them must fail here, loudly.
  describe "jido_ai contract" do
    test "ReAct.run/3 returns exactly result/termination_reason/usage/final_token/trace" do
      FakeReqLlm.install(self(), {:answer, "four", @usage})

      raw = ReAct.run("q", %{model: :auto}, [])

      assert raw |> Map.keys() |> Enum.sort() ==
               [:final_token, :result, :termination_reason, :trace, :usage]

      assert raw.termination_reason == :final_answer
      assert raw.result == "four"
      assert is_map(raw.usage)
    end

    test "a failed ReAct run keeps the same keys with termination_reason :failed" do
      FakeReqLlm.install(self(), {:error, :econnrefused})

      raw = ReAct.run("q", %{model: :auto}, [])

      assert raw |> Map.keys() |> Enum.sort() ==
               [:final_token, :result, :termination_reason, :trace, :usage]

      assert raw.termination_reason == :failed
    end

    test "ChainOfThought exposes no run entrypoint, only the prompt and parsing helpers" do
      assert ChainOfThought.__info__(:functions) |> Keyword.keys() |> Enum.sort() ==
               [
                 :default_system_prompt,
                 :extract_steps_and_conclusion,
                 :generate_call_id,
                 :strategy_module
               ]
    end
  end

  defp mock_react do
    :ok = :meck.new(ReAct, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(ReAct) end)
  end

  defp stub_react_run(raw) do
    :meck.expect(ReAct, :run, fn _prompt, _config, _opts -> raw end)
  end
end
