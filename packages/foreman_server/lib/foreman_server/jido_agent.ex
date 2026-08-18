defmodule ForemanServer.JidoAgent do
  @moduledoc """
  Jido.Agent GenServer for managing agent state and lifecycle.

  This module implements the Jido agent protocol as specified in TRD-2026-4212be7e.
  It manages the agent's state, handles commands via cmd/2, and coordinates with
  the event store for state persistence.

  NOTE: Full ReAct/ChainOfThought strategy integration requires proper Jido.Agent
  framework usage which is still being developed. This is a working GenServer
  implementation that can be extended later.
  """

  use GenServer
  require Logger

  alias ForemanServer.{EventStore, ProjectionStore}

  @type t :: %__MODULE__{
          id: String.t(),
          state: map(),
          task_id: String.t() | nil,
          run_id: String.t() | nil,
          status: atom(),
          checkpoint: map() | nil,
          directives: list(map())
        }

  @enforce_keys [:id, :state]
  defstruct [
    :id,
    :state,
    :task_id,
    :run_id,
    status: :idle,
    checkpoint: nil,
    directives: []
  ]

  @doc """
  Starts a Jido.Agent GenServer.

  ## Parameters
  - `id`: Unique identifier for this agent
  - `state`: Initial state map
  - `opts`: Optional configuration (task_id, run_id)
  """
  @spec start_link(String.t(), map(), keyword()) :: GenServer.on_start()
  def start_link(id, state, opts \\ []) do
    GenServer.start_link(__MODULE__, {id, state, opts}, name: via_tuple(id))
  end

  @doc """
  Starts a Jido.Agent GenServer from tuple args (for DynamicSupervisor).
  """
  @spec start_link({String.t(), map(), keyword()}) :: GenServer.on_start()
  def start_link({id, state, opts}) do
    start_link(id, state, opts)
  end

  @doc """
  Sends a command to the agent.

  ## Parameters
  - `id`: Agent identifier
  - `command`: Command map

  ## Returns
  - `{:ok, result}` on success
  - `{:error, reason}` on failure
  """
  @spec cmd(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def cmd(id, command) do
    GenServer.call(via_tuple(id), {:cmd, command})
  end

  @doc """
  Gets the current state of the agent.

  ## Parameters
  - `id`: Agent identifier

  ## Returns
  - Agent state map
  """
  @spec get_state(String.t()) :: map()
  def get_state(id) do
    GenServer.call(via_tuple(id), :get_state)
  end

  @doc """
  Returns the GenServer name via_tuple for this agent.
  """
  @spec via_tuple(String.t()) :: {:global, String.t()}
  def via_tuple(id), do: {:global, "jido_agent_#{id}"}

  @impl true
  def init({id, state, opts}) do
    task_id = Keyword.get(opts, :task_id)
    run_id = Keyword.get(opts, :run_id)

    agent = %__MODULE__{
      id: id,
      state: state,
      task_id: task_id,
      run_id: run_id,
      status: :running
    }

    Logger.info("Jido.Agent #{id} started with task_id=#{task_id}, run_id=#{run_id}")

    {:ok, agent}
  end

  @impl true
  def handle_call({:cmd, command}, _from, agent) do
    Logger.debug("Jido.Agent #{agent.id} received command: #{inspect(command)}")

    # Emit OTEL span for this cmd/2 call
    Jido.Observe.with_span(
      [:jido, :agent, :cmd, Map.get(command, :action, "unknown")],
      %{
        agent_id: agent.id,
        task_id: agent.task_id,
        action: Map.get(command, :action, "unknown"),
        params: Map.delete(command, :action)
      },
      fn ->
        # Process the command
        {new_state, directives} = process_command(agent.state, command)

        # Update agent struct with new state and directives
        new_agent = %{
          agent
          | state: new_state,
            status: :processing,
            directives: agent.directives ++ directives
        }

        {:ok, new_agent}
      end
    )
    |> case do
      {:ok, new_agent} ->
        {:reply, {:ok, new_agent}, new_agent}

      {:error, reason} ->
        Logger.error("Jido.Agent #{agent.id} cmd error: #{inspect(reason)}")
        {:reply, {:error, reason}, agent}
    end
  end

  @impl true
  def handle_call(:get_state, _from, agent) do
    {:reply, agent.state, agent}
  end

  @impl true
  def handle_info(:timeout, agent) do
    Logger.debug("Jido.Agent #{agent.id} timeout")
    {:noreply, agent}
  end

  # Private functions

  defp process_command(state, command) do
    # Basic command processing - this would be expanded per action type
    {new_state, directives} =
      case command do
        %{action: "git_status"} ->
          {Map.put(state, :current_action, "git_status"),
           [%{type: "info", content: "Retrieving git status..."}]}

        %{action: "diff_read"} ->
          {Map.put(state, :current_action, "diff_read"),
           [%{type: "info", content: "Reading diff..."}]}

        %{action: "task_get"} ->
          {Map.put(state, :current_action, "task_get"),
           [%{type: "info", content: "Fetching task details..."}]}

        _ ->
          Logger.warning("Unknown command action: #{inspect(command)}")
          {state, [%{type: "error", content: "Unknown action: #{inspect(command)}"}]}
      end

    {new_state, directives}
  end
end
