defmodule ForemanServer.Agents.McpAllowlist do
  @moduledoc """
  MCP security allowlist.

  Rejects calls to tools outside the allowlist, logs security events, and
  tracks a denied-call counter. TRD-2026-4212be7e / MCP-T005 / TRD-052.
  """

  use GenServer

  require Logger

  defstruct allowlist: [], denied_count: 0

  ## Public API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Check whether `tool_id` is on the allowlist."
  def permit?(tool_id), do: GenServer.call(__MODULE__, {:permit?, tool_id})

  @doc "Add `tool_id` to the allowlist."
  def add(tool_id), do: GenServer.call(__MODULE__, {:add, tool_id})

  @doc "Remove `tool_id` from the allowlist."
  def remove(tool_id), do: GenServer.call(__MODULE__, {:remove, tool_id})

  @doc "Return the current allowlist."
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "Return the cumulative denied-call count."
  def denied_count, do: GenServer.call(__MODULE__, :denied_count)

  ## GenServer callbacks

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:permit?, tool_id}, _from, state) do
    if tool_id in state.allowlist do
      {:reply, true, state}
    else
      Logger.warning("MCP allowlist denied: tool=#{tool_id}")
      {:reply, false, %{state | denied_count: state.denied_count + 1}}
    end
  end

  @impl true
  def handle_call({:add, tool_id}, _from, state) do
    {:reply, :ok, %{state | allowlist: Enum.uniq([tool_id | state.allowlist])}}
  end

  @impl true
  def handle_call({:remove, tool_id}, _from, state) do
    {:reply, :ok, %{state | allowlist: Enum.reject(state.allowlist, &(&1 == tool_id))}}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, state.allowlist, state}

  @impl true
  def handle_call(:denied_count, _from, state), do: {:reply, state.denied_count, state}
end
