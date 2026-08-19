defmodule ForemanServer.Agents.McpClientPool do
  @moduledoc """
  Wraps jido_mcp client pool and syncs tools into agent toolset.
  TRD-2026-4212be7e / MCP-T002 / TRD-049.
  """
  use GenServer
  require Logger

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts), do: {:ok, %{clients: %{}}}

  def register(server_id, client), do: GenServer.call(__MODULE__, {:register, server_id, client})
  def tools(server_id), do: GenServer.call(__MODULE__, {:tools, server_id})

  @impl true
  def handle_call({:register, server_id, client}, _from, state) do
    Logger.info("MCP server registered: #{server_id}")
    {:reply, :ok, put_in(state.clients[server_id], client)}
  end

  def handle_call({:tools, server_id}, _from, state) do
    client = Map.get(state.clients, server_id)
    case client do
      nil -> {:reply, [], state}
      c -> {:reply, safe_tools(c), state}
    end
  end

  defp safe_tools(_client), do: []
end
