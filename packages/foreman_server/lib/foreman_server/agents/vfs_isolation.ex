defmodule ForemanServer.Agents.VfsIsolation do
  @moduledoc """
  VFS isolation per worktree: each agent gets a sandboxed filesystem view.

  Maintains a per-agent binding from `agent_id` to a worktree root
  directory, and answers `allowed?/2` queries by checking whether a
  requested path falls under the agent's bound worktree root.

  TRD-2026-4212be7e / JSH-T003 / TRD-034.
  """
  use GenServer
  require Logger

  @table :foreman_vfs_isolation

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table])
    {:ok, %{}}
  end

  @doc """
  Bind an `agent_id` to a `worktree_path`. Re-binding the same
  `agent_id` replaces the previous binding.
  """
  def bind(agent_id, worktree_path) do
    GenServer.call(__MODULE__, {:bind, agent_id, worktree_path})
  end

  @doc """
  Look up the bound worktree path for `agent_id`. Returns
  `{:ok, path}` or `:not_found`.
  """
  def lookup(agent_id), do: GenServer.call(__MODULE__, {:lookup, agent_id})

  @doc """
  Remove the binding for `agent_id`. Idempotent — no error if the
  agent is not bound.
  """
  def unbind(agent_id), do: GenServer.call(__MODULE__, {:unbind, agent_id})

  @doc """
  Returns `true` if `path` is under the bound worktree for `agent_id`,
  `false` otherwise (including when the agent has no binding).
  """
  def allowed?(agent_id, path), do: GenServer.call(__MODULE__, {:allowed?, agent_id, path})

  @impl true
  def handle_call({:bind, agent_id, worktree_path}, _from, state) do
    :ets.insert(@table, {agent_id, worktree_path})
    Logger.info("VFS bound: agent=#{agent_id} worktree=#{worktree_path}")
    {:reply, :ok, state}
  end

  def handle_call({:lookup, agent_id}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, path}] -> {:reply, {:ok, path}, state}
      [] -> {:reply, :not_found, state}
    end
  end

  def handle_call({:unbind, agent_id}, _from, state) do
    :ets.delete(@table, agent_id)
    Logger.info("VFS unbound: agent=#{agent_id}")
    {:reply, :ok, state}
  end

  def handle_call({:allowed?, agent_id, path}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, worktree}] ->
        {:reply, String.starts_with?(path, worktree), state}
      [] ->
        {:reply, false, state}
    end
  end
end