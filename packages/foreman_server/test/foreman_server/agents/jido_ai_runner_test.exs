defmodule ForemanServer.Agents.JidoAiRunnerTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.JidoAiRunner` — integration surface
  between Foreman and the jido_ai reasoning strategies (ReAct and
  Chain-of-Thought). TRD-2026-4212be7e / JAI-T001 / TRD-039.
  """

  use ExUnit.Case, async: true

  @moduletag :integration
  

  alias ForemanServer.Agents.JidoAiRunner

  test "unknown strategy returns :unknown_strategy error" do
    assert {:error, :unknown_strategy} = JidoAiRunner.run(:bogus, "test prompt")
  end

  test "react strategy resolves" do
    case JidoAiRunner.run(:react, "What is 2 + 2?") do
      {:ok, %{strategy: :react}} -> :ok
      other -> flunk("expected ok map with strategy=:react, got #{inspect(other)}")
    end
  end

  test "cot strategy resolves" do
    case JidoAiRunner.run(:cot, "Explain photosynthesis.") do
      {:ok, %{strategy: :cot}} -> :ok
      other -> flunk("expected ok map with strategy=:cot, got #{inspect(other)}")
    end
  end

  test "react passes through model option" do
    # We don't assert on the actual model passed downstream, just that
    # the call doesn't crash when the caller supplies :model.
    assert {:ok, _} = JidoAiRunner.run(:react, "hello", model: "openai:gpt-4o")
  end

  test "cot passes through model + config options" do
    assert {:ok, _} =
             JidoAiRunner.run(:cot, "hello",
               model: "openai:gpt-4o",
               config: %{step_count: 3}
             )
  end
end
