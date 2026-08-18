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

  alias Jido.AI.Reasoning.ChainOfThought
  alias Jido.AI.Reasoning.ReAct

  @doc """
  Creates a ChainOfThought agent.

  This creates a Jido.Agent module configured with the ChainOfThought strategy.
  The returned module can be started as a GenServer.

  ## Parameters
  - `opts`: Configuration options including system_prompt, model, etc.

  ## Returns
  - `{:ok, agent_module}` on success
  - `{:error, reason}` on failure

  ## Example
      {:ok, agent_module} = ForemanServer.JidoAI.Integration.create_cot_agent(
        system_prompt: "You are a helpful assistant",
        model: "gpt-4"
      )
  """
  @spec create_cot_agent(keyword()) :: {:ok, module()} | {:error, term()}
  def create_cot_agent(opts) when is_list(opts) do
    try do
      system_prompt = Keyword.get(opts, :system_prompt, ChainOfThought.default_system_prompt())
      strategy_opts = Keyword.get(opts, :strategy_opts, [system_prompt: system_prompt])
      model = Keyword.get(opts, :model)

      # Define a new agent module with ChainOfThought strategy
      agent_module = Module.safe_concat([ForemanServer, "JidoAI.COT.", Macro.camelize(System.unique_integer([:positive]))])

      Code.eval_string("""
      defmodule #{agent_module} do
        use Jido.Agent,
          strategy: Jido.AI.Reasoning.ChainOfThought.Strategy,
          strategy_opts: unquote(strategy_opts)

        @impl true
        def handle_info({:action, action}, state) do
          # Execute action through the strategy
          {:noreply, state}
        end
      end
      """)

      {:ok, agent_module}
    rescue
      error -> {:error, error}
    end
  end

  @doc """
  Creates a ReAct agent.

  This creates a Jido.Agent module configured with the ReAct strategy.
  The returned module can be started as a GenServer.

  ## Parameters
  - `opts`: Configuration options including system_prompt, model, etc.

  ## Returns
  - `{:ok, agent_module}` on success
  - `{:error, reason}` on failure

  ## Example
      {:ok, agent_module} = ForemanServer.JidoAI.Integration.create_react_agent(
        system_prompt: "You are a helpful assistant",
        model: "gpt-4"
      )
  """
  @spec create_react_agent(keyword()) :: {:ok, module()} | {:error, term()}
  def create_react_agent(opts) when is_list(opts) do
    try do
      system_prompt = Keyword.get(opts, :system_prompt, "You are a helpful assistant")
      strategy_opts = Keyword.get(opts, :strategy_opts, [system_prompt: system_prompt])
      model = Keyword.get(opts, :model)

      # Define a new agent module with ReAct strategy
      agent_module = Module.safe_concat([ForemanServer, "JidoAI.React.", Macro.camelize(System.unique_integer([:positive]))])

      Code.eval_string("""
      defmodule #{agent_module} do
        use Jido.Agent,
          strategy: Jido.AI.Reasoning.ReAct.Strategy,
          strategy_opts: unquote(strategy_opts)

        @impl true
        def handle_info({:action, action}, state) do
          # Execute action through the strategy
          {:noreply, state}
        end
      end
      """)

      {:ok, agent_module}
    rescue
      error -> {:error, error}
    end
  end

  @doc """
  Run a ChainOfThought reasoning step.

  This function executes a reasoning step using the ChainOfThought strategy.
  It creates an agent if one doesn't exist, executes the action, and returns
  the result with any directives.

  ## Parameters
  - `agent`: The Jido.Agent GenServer PID or name, or `:none` to create a new one
  - `action`: The action/instruction to execute

  ## Returns
  - `{:ok, {agent, directives}}` on success
  - `{:error, reason}` on failure

  ## Example
      {:ok, {agent, directives}} = ForemanServer.JidoAI.Integration.run_chain_of_thought(
        :none,
        "What is the capital of France?"
      )
  """
  @spec run_chain_of_thought(term(), term()) :: {:ok, {term(), term()}} | {:error, term()}
  def run_chain_of_thought(agent, action) do
    try do
      # Create a temporary agent if not provided
      {agent, _} =
        case agent do
          :none ->
            {:ok, agent_module} = create_cot_agent([])
            {:ok, pid} = Jido.Agent.start_link(agent_module, %{})
            {pid, agent_module}

          pid when is_pid(pid) ->
            {pid, nil}

          name when is_atom(name) ->
            {name, nil}
        end

      # Execute the action using ChainOfThought
      result = ChainOfThought.stream(action, %{}, [])
      collected = ReAct.collect_stream(result)

      {:ok, {agent, collected}}
    rescue
      error -> {:error, error}
    end
  end

  @doc """
  Run a ReAct reasoning step.

  This function executes a reasoning step using the ReAct strategy.
  It creates an agent if one doesn't exist, executes the action, and returns
  the result with any directives.

  ## Parameters
  - `agent`: The Jido.Agent GenServer PID or name, or `:none` to create a new one
  - `action`: The action/instruction to execute

  ## Returns
  - `{:ok, {agent, directives}}` on success
  - `{:error, reason}` on failure

  ## Example
      {:ok, {agent, directives}} = ForemanServer.JidoAI.Integration.run_react(
        :none,
        "What is the capital of France?"
      )
  """
  @spec run_react(term(), term()) :: {:ok, {term(), term()}} | {:error, term()}
  def run_react(agent, action) do
    try do
      # Create a temporary agent if not provided
      {agent, _} =
        case agent do
          :none ->
            {:ok, agent_module} = create_react_agent([])
            {:ok, pid} = Jido.Agent.start_link(agent_module, %{})
            {pid, agent_module}

          pid when is_pid(pid) ->
            {pid, nil}

          name when is_atom(name) ->
            {name, nil}
        end

      # Execute the action using ReAct
      result = ReAct.run(action, %{}, [])

      {:ok, {agent, result}}
    rescue
      error -> {:error, error}
    end
  end
end
