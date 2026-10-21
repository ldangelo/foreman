defmodule ForemanServer.Agents.VfsIsolation do
  @moduledoc """
  VFS isolation per worktree: each agent gets a sandboxed filesystem view.

  Maintains a per-agent binding from `agent_id` to one or more worktree root
  directories (one per repository of a run), and answers `allowed?/2` queries
  by checking whether a requested path falls under any bound root.
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
  Bind an `agent_id` to one or more worktree `roots`. A single path is
  accepted as `[path]`. Every root is canonicalised (`canonical_path/1`) at
  bind time, so a symlinked root is bound as the directory it points at.
  Re-binding the same `agent_id` REPLACES the previous binding - a
  multi-repository run must therefore bind all of its roots in one call.
  """
  @spec bind(String.t(), String.t() | [String.t()]) :: :ok
  def bind(agent_id, roots) do
    roots = roots |> List.wrap() |> Enum.map(&canonical_path/1)
    GenServer.call(__MODULE__, {:bind, agent_id, roots})
  end

  @doc """
  Look up the bound (canonical) roots for `agent_id`. Returns
  `{:ok, [root]}` or `:not_found`.
  """
  @spec lookup(String.t()) :: {:ok, [String.t()]} | :not_found
  def lookup(agent_id), do: GenServer.call(__MODULE__, {:lookup, agent_id})

  @doc """
  Remove the binding for `agent_id`. Idempotent — no error if the
  agent is not bound.
  """
  def unbind(agent_id), do: GenServer.call(__MODULE__, {:unbind, agent_id})

  @doc """
  Returns `true` if `path` is a bound root or lies under one, `false`
  otherwise (including when the agent has no binding). Containment is
  decided on canonical paths (`canonical_path/1`): `..` traversal and
  symlinks that point outside every root are denied, and the match respects
  a `/` boundary, so `/wt/a-evil` is not under `/wt/a`.
  """
  @spec allowed?(String.t(), String.t()) :: boolean()
  def allowed?(agent_id, path) do
    GenServer.call(__MODULE__, {:allowed?, agent_id, path, canonical_path(path)})
  end

  @doc """
  Canonical form of `path`: absolute, `.`/`..` resolved, and every existing
  component's symlink followed (realpath). Components that do not exist yet
  (a file about to be created) are appended lexically normalised.
  """
  @spec canonical_path(String.t()) :: String.t()
  def canonical_path(path) when is_binary(path) do
    path |> Path.expand() |> Path.split() |> resolve_parts([], 0) |> join_parts()
  end

  @max_symlink_depth 40

  # `acc` holds the resolved prefix in reverse. A symlink restarts resolution
  # with its target (relative targets are relative to the link's directory).
  defp resolve_parts([], acc, _depth), do: Enum.reverse(acc)
  defp resolve_parts(["/" | rest], _acc, depth), do: resolve_parts(rest, ["/"], depth)
  defp resolve_parts(["." | rest], acc, depth), do: resolve_parts(rest, acc, depth)
  defp resolve_parts([".." | rest], ["/"] = acc, depth), do: resolve_parts(rest, acc, depth)
  defp resolve_parts([".." | rest], [_ | acc], depth), do: resolve_parts(rest, acc, depth)

  defp resolve_parts([part | rest], acc, depth) do
    candidate = join_parts(Enum.reverse([part | acc]))

    case File.read_link(candidate) do
      {:ok, target} when depth < @max_symlink_depth ->
        base = join_parts(Enum.reverse(acc))
        resolve_parts(Path.split(Path.expand(target, base)) ++ rest, [], depth + 1)

      _ ->
        resolve_parts(rest, [part | acc], depth)
    end
  end

  defp join_parts(["/"]), do: "/"
  defp join_parts(parts), do: Path.join(parts)

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

      if Enum.any?(allowed_roots, &under_root?(canonical_path(worktree_path), canonical_path(&1))) do
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
  @spec bind_with_check(String.t(), String.t() | [String.t()]) ::
          :ok | {:error, :worktree_not_in_allowed_list}
  def bind_with_check(agent_id, roots) do
    roots = List.wrap(roots)

    case Enum.find_value(roots, :ok, fn root ->
           with :ok <- allowlist_check(root), do: nil
         end) do
      :ok -> bind(agent_id, roots)
      error -> error
    end
  end

  defp under_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  @impl true
  def handle_call({:bind, agent_id, roots}, _from, state) do
    :ets.insert(@table, {agent_id, roots})
    Logger.info("VFS bound: agent=#{agent_id} roots=#{Enum.join(roots, ",")}")
    {:reply, :ok, state}
  end

  def handle_call({:lookup, agent_id}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, roots}] -> {:reply, {:ok, roots}, state}
      [] -> {:reply, :not_found, state}
    end
  end

  def handle_call({:unbind, agent_id}, _from, state) do
    :ets.delete(@table, agent_id)
    Logger.info("VFS unbound: agent=#{agent_id}")
    {:reply, :ok, state}
  end

  def handle_call({:allowed?, agent_id, path, canonical}, _from, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, roots}] ->
        if Enum.any?(roots, &under_root?(canonical, &1)) do
          {:reply, true, state}
        else
          # Access denied - log and emit security telemetry
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
