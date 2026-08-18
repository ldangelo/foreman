defmodule ForemanServer.JidoAI.Integration do
  @moduledoc """
  Integration module for Jido.AI strategies with req_llm.

  This module provides functions for running ReAct and Chain-of-Thought
  reasoning strategies using the Jido.AI library.

  ## ChainOfThought Strategy

  ChainOfThought is used as a Jido.Agent strategy. To use it:

      defmodule MyAgent do
        use Jido.Agent,
          strategy: Jido.AI.Reasoning.ChainOfThought.Strategy,
          strategy_opts: [system_prompt: "Your system prompt"]
      end

  ## ReAct Strategy

  ReAct is used as a Jido.Agent strategy. To use it:

      defmodule MyAgent do
        use Jido.Agent,
          strategy: Jido.AI.Reasoning.ReAct.Strategy,
          strategy_opts: [system_prompt: "Your system prompt"]
      end
  """

  alias Jido.AI.Reasoning.ReAct

  @doc """
  Run a ReAct reasoning step.

  This function executes a reasoning step using the ReAct strategy.
  It runs the ReAct reasoning directly without creating an agent.

  ## Parameters
  - `action`: The action/instruction to execute

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure

  ## Example
      {:ok, result} = ForemanServer.JidoAI.Integration.run_react(
        "What is the capital of France?"
      )
  """
  @spec run_react(term()) :: {:ok, term()} | {:error, term()}
  def run_react(action) do
    try do
      # Execute the action using ReAct
      result = ReAct.run(action, %{}, [])

      {:ok, result}
    rescue
      error -> {:error, error}
    end
  end
end
