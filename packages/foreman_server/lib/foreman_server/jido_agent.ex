defmodule ForemanServer.JidoAgent do
  @moduledoc """
  Jido.Agent GenServer for managing agent state and lifecycle with ReAct strategy.

  This module implements the Jido agent protocol as specified in TRD-2026-4212be7e.
  It uses Jido.Agent.Strategy.ReAct for reasoning and integrates with jido_signal
  for communication.
  """

  use Jido.Agent,
    name: "foreman_agent",
    description: "Foreman Jido Agent with ReAct reasoning strategy",
    strategy: {Jido.AI.Reasoning.ReAct.Strategy, [system_prompt: "You are a Foreman agent that helps with task execution and management."]},
    schema: [
      status: [type: :atom, default: :idle],
      task_id: [type: :string, default: nil],
      run_id: [type: :string, default: nil]
    ]

  require Logger

  @doc """
  Creates a new Foreman Agent.

  ## Parameters
  - `opts`: Configuration options

  ## Returns
  - `{:ok, agent}` on success
  - `{:error, reason}` on failure
  """
  @spec new(keyword()) :: {:ok, Jido.Agent.t()} | {:error, term()}
  def new(opts) do
    Jido.Agent.new(__MODULE__, opts)
  end

  @doc """
  Starts a Foreman Agent GenServer.

  ## Parameters
  - `opts`: Configuration options (task_id, run_id, etc.)

  ## Returns
  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Jido.AgentServer.start_link(__MODULE__, opts)
  end

  @doc """
  Starts a Foreman Agent GenServer under a DynamicSupervisor.

  ## Parameters
  - `opts`: Configuration options (task_id, run_id, etc.)

  ## Returns
  - `{:ok, pid}` on success
  - `{:error, reason}` on failure
  """
  @spec start(keyword()) :: DynamicSupervisor.on_start_child()
  def start(opts \\ []) do
    Jido.AgentServer.start(__MODULE__, opts)
  end

  @doc """
  Sends a command to the agent using Jido.Agent's cmd/2 function.

  ## Parameters
  - `agent`: Agent reference
  - `command`: Command map with action and parameters

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure
  """
  @spec cmd(any(), map()) :: {:ok, term()} | {:error, term()}
  def cmd(agent, command) do
    # Extract action from command
    action = Map.get(command, :action, "unknown")
    
    # Call Jido.AgentServer.call with :cmd message
    Jido.AgentServer.call(agent, :cmd, command)
  end

  @doc """
  Gets the current state of the agent.

  ## Parameters
  - `agent`: Agent reference

  ## Returns
  - `{:ok, state}` on success
  - `{:error, reason}` on failure
  """
  @spec state(any()) :: {:ok, map()} | {:error, term()}
  def state(agent) do
    Jido.AgentServer.state(agent)
  end

  @doc """
  Stops the agent.

  ## Parameters
  - `agent`: Agent reference

  ## Returns
  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec stop(any()) :: :ok | {:error, term()}
  def stop(agent) do
    Jido.AgentServer.stop(agent)
  end

  @doc """
  Waits for agent completion.

  ## Parameters
  - `agent`: Agent reference
  - `opts`: Options including timeout

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure
  """
  @spec await_completion(any(), keyword()) :: {:ok, term()} | {:error, term()}
  def await_completion(agent, opts \\ []) do
    Jido.AgentServer.await_completion(agent, opts)
  end

  @doc """
  Returns the process identifier for this agent.
  """
  @spec pid(keyword()) :: pid() | nil
  def pid(opts \\ []) do
    Jido.AgentServer.whereis(__MODULE__, :foreman_agent, opts)
  end

  @doc """
  Checks if the agent is alive.
  """
  @spec alive?(keyword()) :: boolean()
  def alive?(opts \\ []) do
    case pid(opts) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end
end
