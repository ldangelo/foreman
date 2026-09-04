defmodule ForemanServer.Agents.VfsIsolation do
  @moduledoc """
  VFS isolation per worktree: each agent gets a sandboxed filesystem view.

  Maintains a per-agent binding from `agent_id` to a worktree root
  directory, and answers `allowed?/2` queries by checking whether a
  requested path falls under the agent's bound worktree root.
  When access is denied (`false`) a security event is emitted via
  `:telemetry.execute([:foreman_server, :security, :vfs_denied], ...)`
  with `agent_id`, `path`, and `reason` (`:outside_worktree | :no_binding`).

  TRD-2026-4212be7e / JSH-T003 / TRD-034 / LGC-T001 / TRD-096.
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

  @doc """
  Returns `:ok` if `worktree_path` is under one of the configured
  allowed roots (from `:jido_vfs, :allowed_roots`), or
  `{:error, :worktree_not_in_allowed_list}` if the allowlist is
  enforced and the path is not under any allowed root.
  """
  @spec allowlist_check(String.t()) :: :ok | {:error, :worktree_not_in_allowed_list}
  def allowlist_check(worktree_path) do
    enforce? =
      Application.get_env(:foreman_server, :jido_vfs, []) |> Keyword.get(:enforce_allowlist, true)

    if enforce? do
      allowed_roots =
        Application.get_env(:foreman_server, :jido_vfs, []) |> Keyword.get(:allowed_roots, [])

      if Enum.any?(allowed_roots, &String.starts_with?(worktree_path, &1)) do
        :ok
      else
        {:error, :worktree_not_in_allowed_list}
      end
    else
      :ok
    end
  end

  @doc """
  Convenience wrapper: checks the allowlist and then binds if permitted.
  Returns `:ok` on success or `{:error, :worktree_not_in_allowed_list}`.
  """
  @spec bind_with_check(String.t(), String.t()) :: :ok | {:error, :worktree_not_in_allowed_list}
  def bind_with_check(agent_id, worktree_path) do
    case allowlist_check(worktree_path) do
      :ok -> bind(agent_id, worktree_path)
      error -> error
    end
  end

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
        allowed = String.starts_with?(path, worktree)

        if allowed do
          {:reply, true, state}
        else
          # Access denied — log and emit security telemetry
          Logger.warning(
            "VFS sandbox denied: agent=#{agent_id} path=#{path} reason=outside_worktree"
          )

          :telemetry.execute([:foreman_server, :security, :vfs_denied], %{count: 1}, %{
            agent_id: agent_id,
            path: path,
            reason: :outside_worktree
          })

          {:reply, false, state}
        end

      [] ->
        Logger.warning("VFS sandbox denied: agent=#{agent_id} path=#{path} reason=no_binding")

        :telemetry.execute([:foreman_server, :security, :vfs_denied], %{count: 1}, %{
          agent_id: agent_id,
          path: path,
          reason: :no_binding
        })

        {:reply, false, state}
    end
  end
end
