defmodule ForemanServer.Approvals.Live do
  @moduledoc """
  Registry of provider-session approval requests that are waiting for a decision
  (`:live` delivery, see `ForemanServer.Approvals.Capability`).

  A process that owns a `Jido.Harness.Session` and sees an `:approval_requested`
  event registers it here (`register/5`) right after recording the request with
  `ForemanServer.Approvals.Requester`. When the operator decides, the Deliverer
  calls `respond/4`, which removes the entry and answers the session
  (`Session.respond_approval/3`). An entry for a call nobody registered (the
  common case today: Foreman's workflow door runs one-shot agents, not sessions)
  yields `{:error, :no_live_request}`, which the Deliverer surfaces as a failed
  delivery instead of pretending the agent heard it.
  """

  use GenServer

  alias ForemanServer.AgentRuntime.JidoHarness.Session

  @type decision :: :approve | :deny

  @doc "Start the registry (name defaults to this module)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Record the session request that answers `run_id`/`tool_call_id`."
  @spec register(GenServer.server(), String.t(), String.t(), String.t(), String.t()) :: :ok
  def register(server \\ __MODULE__, run_id, tool_call_id, session_id, request_id) do
    GenServer.call(server, {:register, {run_id, tool_call_id}, {session_id, request_id}})
  end

  @doc """
  Answer the registered request. `opts`: `:server` (registry), `:session_module`
  (default `ForemanServer.AgentRuntime.JidoHarness.Session`, a test seam).
  """
  @spec respond(String.t(), String.t(), decision(), keyword()) :: :ok | {:error, term()}
  def respond(run_id, tool_call_id, decision, opts \\ []) when decision in [:approve, :deny] do
    server = Keyword.get(opts, :server, __MODULE__)
    session_module = Keyword.get(opts, :session_module, Session)

    case GenServer.call(server, {:take, {run_id, tool_call_id}}) do
      {:ok, {session_id, request_id}} ->
        session_module.respond_approval(session_id, request_id, decision)

      :error ->
        {:error, :no_live_request}
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:register, key, value}, _from, state),
    do: {:reply, :ok, Map.put(state, key, value)}

  def handle_call({:take, key}, _from, state) do
    case Map.pop(state, key) do
      {nil, state} -> {:reply, :error, state}
      {value, state} -> {:reply, {:ok, value}, state}
    end
  end
end
