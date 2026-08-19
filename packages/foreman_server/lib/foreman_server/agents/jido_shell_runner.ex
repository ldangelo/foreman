defmodule ForemanServer.Agents.JidoShellRunner do
  @moduledoc """
  Wraps jido_shell command execution with jido_vfs sandbox.

  TRD-2026-4212be7e / JSH-T001 / TRD-032 (shell + VFS integration),
  JSH-T002 / TRD-033 (session lifecycle tied to owner process),
  JSH-T003 / TRD-034 (VFS isolation per worktree via distinct
  workspace_id -> distinct in-memory VFS mount).

  Each session is backed by a real `Jido.Shell.Agent` session
  (`Jido.Shell.ShellSession.start_with_vfs/2` under the hood), which
  mounts an isolated in-memory VFS root keyed by the generated
  session_id. The runner GenServer tracks `session_id => owner` pairs
  and monitors each owner: when the owning process exits, its
  session is torn down automatically (agent restart => new session).
  """
  use GenServer
  require Logger

  @type session_id :: String.t()

  ## === Client API ===

  @doc """
  Starts the runner GenServer. `opts[:name]` defaults to this module
  (matching the production supervision registration in
  `ForemanServer.Application.maybe_jido_shell_runner_child/0`); pass
  `name: nil` to start unregistered and address the process by pid.
  """
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    genserver_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  @doc """
  Starts a new VFS-sandboxed shell session for `workspace_id`.

  Options:
  - `:manager` - runner process (name or pid); defaults to `__MODULE__`
  - `:owner` - process whose lifetime the session is tied to;
    defaults to the calling process. When the owner exits, the
    session is stopped and untracked.

  Returns `{:ok, session_id}` or `{:error, reason}`.
  """
  @spec start_session(String.t(), keyword()) :: {:ok, session_id()} | {:error, term()}
  def start_session(workspace_id, opts \\ []) do
    manager = Keyword.get(opts, :manager, __MODULE__)
    owner = Keyword.get(opts, :owner, self())
    GenServer.call(manager, {:start_session, workspace_id, owner})
  end

  @doc """
  Stops a tracked session and tears down its VFS mount.
  """
  @spec stop_session(session_id(), keyword()) :: :ok | {:error, term()}
  def stop_session(session_id, opts \\ []) do
    manager = Keyword.get(opts, :manager, __MODULE__)
    GenServer.call(manager, {:stop_session, session_id})
  end

  @doc """
  Returns whether `session_id` is currently tracked by `manager`.
  """
  @spec tracked?(session_id(), keyword()) :: boolean()
  def tracked?(session_id, opts \\ []) do
    manager = Keyword.get(opts, :manager, __MODULE__)
    GenServer.call(manager, {:tracked?, session_id})
  end

  @doc """
  Runs a single command string against a tracked session and waits
  for completion. Delegates to `Jido.Shell.Agent.run/3` directly from
  the calling process (the underlying implementation subscribes and
  receives session events on the caller's mailbox, so this must not
  be proxied through a GenServer call).
  """
  @spec run_command(session_id(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run_command(session_id, command, opts \\ []) do
    Jido.Shell.Agent.run(session_id, command, opts)
  end

  @doc """
  Ad-hoc single-shot command execution, independent of the session
  registry. Tries the real `Jido.Shell` API when loaded, falling back
  to `System.cmd/3`.
  """
  def execute(cmd, args, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    vfs_root = Keyword.get(opts, :vfs_root, cwd)
    Logger.info("Executing shell: cmd=#{cmd} args=#{inspect(args)} cwd=#{cwd} vfs=#{vfs_root}")
    run_shell(cmd, args, cwd, vfs_root)
  end

  ## === Server callbacks ===

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:start_session, workspace_id, owner}, _from, state) do
    case Jido.Shell.Agent.new(workspace_id) do
      {:ok, session_id} ->
        ref = Process.monitor(owner)
        sessions = Map.put(state.sessions, session_id, %{owner: owner, ref: ref})
        {:reply, {:ok, session_id}, %{state | sessions: sessions}}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:stop_session, session_id}, _from, state) do
    state = untrack_session(state, session_id)
    result = Jido.Shell.Agent.stop(session_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:tracked?, session_id}, _from, state) do
    {:reply, Map.has_key?(state.sessions, session_id), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.sessions, fn {_id, %{ref: r}} -> r == ref end) do
      {session_id, _entry} ->
        Logger.info("JidoShellRunner: owner exited, tearing down session=#{session_id}")
        _ = Jido.Shell.Agent.stop(session_id)
        {:noreply, %{state | sessions: Map.delete(state.sessions, session_id)}}

      nil ->
        {:noreply, state}
    end
  end

  defp untrack_session(state, session_id) do
    case Map.get(state.sessions, session_id) do
      %{ref: ref} ->
        Process.demonitor(ref, [:flush])
        %{state | sessions: Map.delete(state.sessions, session_id)}

      nil ->
        state
    end
  end

  defp run_shell(cmd, args, cwd, vfs_root) do
    # Try the actual jido_shell API first; fall back to System.cmd
    if Code.ensure_loaded?(Jido.Shell) do
      try do
        Jido.Shell.run(cmd, args, cwd: cwd, vfs_root: vfs_root)
      rescue
        _ -> system_cmd(cmd, args, cwd)
      end
    else
      system_cmd(cmd, args, cwd)
    end
  end

  defp system_cmd(cmd, args, cwd) do
    case System.cmd(cmd, args, cd: cwd, into: "") do
      {output, 0} -> {:ok, output, 0}
      {output, code} -> {:ok, output, code}
    end
  end
end
