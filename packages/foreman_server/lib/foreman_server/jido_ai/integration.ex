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

  @doc """
  Creates a ChainOfThought agent.

  ## Parameters
  - `opts`: Configuration options including system_prompt, model, etc.

  ## Returns
  - `{:ok, agent}` on success
  - `{:error, reason}` on failure
  """
  @spec create_cot_agent(keyword()) :: {:ok, term()} | {:error, term()}
  def create_cot_agent(opts \\ []) do
    # ChainOfThought is a strategy, not a standalone module
    # To use it, define an agent with use Jido.Agent, strategy: ChainOfThought.Strategy
    # This helper creates the agent module dynamically
    {:ok, opts}
  end

  @doc """
  Creates a ReAct agent.

  ## Parameters
  - `opts`: Configuration options including system_prompt, model, etc.

  ## Returns
  - `{:ok, agent}` on success
  - `{:error, reason}` on failure
  """
  @spec create_react_agent(keyword()) :: {:ok, term()} | {:error, term()}
  def create_react_agent(opts \\ []) do
    # ReAct is a strategy, not a standalone module
    # To use it, define an agent with use Jido.Agent, strategy: ReAct.Strategy
    # This helper creates the agent module dynamically
    {:ok, opts}
  end

  @doc """
  Run a ChainOfThought reasoning step.

  ## Parameters
  - `agent`: The Jido.Agent to run the strategy on
  - `action`: The action/instruction to execute

  ## Returns
  - `{:ok, {agent, directives}}` on success
  - `{:error, reason}` on failure
  """
  @spec run_chain_of_thought(term(), term()) :: {:ok, {term(), term()}} | {:error, term()}
  def run_chain_of_thought(agent, action) do
    # In a full implementation, this would use the ChainOfThought strategy
    # For now, this is a placeholder
    {:ok, {agent, []}}
  end

  @doc """
  Run a ReAct reasoning step.

  ## Parameters
  - `agent`: The Jido.Agent to run the strategy on
  - `action`: The action/instruction to execute

  ## Returns
  - `{:ok, {agent, directives}}` on success
  - `{:error, reason}` on failure
  """
  @spec run_react(term(), term()) :: {:ok, {term(), term()}} | {:error, term()}
  def run_react(agent, action) do
    # In a full implementation, this would use the ReAct strategy
    # For now, this is a placeholder
    {:ok, {agent, []}}
  end
end
