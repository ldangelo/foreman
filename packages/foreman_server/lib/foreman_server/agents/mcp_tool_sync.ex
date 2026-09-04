defmodule ForemanServer.Agents.McpToolSync do
  @moduledoc """
  Syncs registered MCP server tools into the agent's available toolset.
  TRD-2026-4212be7e / MCP-T003 / TRD-050.
  """
  use GenServer
  require Logger
  alias ForemanServer.Agents.McpClientPool

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: {:ok, %{tool_cache: %{}}}

  def sync(server_ids), do: GenServer.call(__MODULE__, {:sync, server_ids})
  def tools_for(server_id), do: GenServer.call(__MODULE__, {:tools, server_id})
  def all_tools, do: GenServer.call(__MODULE__, :all_tools)

  @impl true
  def handle_call({:sync, server_ids}, _from, state) do
    new_cache = Map.new(server_ids, fn sid -> {sid, McpClientPool.tools(sid)} end)
    merged = Map.merge(state.tool_cache, new_cache)
    total = merged |> Enum.map(fn {_, t} -> length(t) end) |> Enum.sum()
    Logger.info("MCP tool sync complete; total tools: #{total}")
    {:reply, :ok, %{state | tool_cache: merged}}
  end

  def handle_call({:tools, server_id}, _from, state) do
    {:reply, Map.get(state.tool_cache, server_id, []), state}
  end

  def handle_call(:all_tools, _from, state) do
    {:reply, state.tool_cache, state}
  end
end
