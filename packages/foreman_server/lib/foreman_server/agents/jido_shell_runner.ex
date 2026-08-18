defmodule ForemanServer.Agents.JidoShellRunner do
  @moduledoc """
  Foreman-side runner that delegates to `Jido.Shell.ShellSession`
  (TRD-2026-4212be7e, JSH-T001/JSH-T002).

  The Foreman action layer needs a way to execute shell commands
  on behalf of Jido agents, with a sandboxed VFS. Upstream
  `Jido.Shell` provides the in-memory virtual workspace shell with
  the `Jido.Shell.ShellSession` / `Jido.Shell.ShellSessionServer`
  surface; this module is a thin Foreman wrapper so the rest of
  the codebase has a single Foreman call point.

  ## Lifecycle contract

  JSH-T002 requires shell sessions to be tied to the owning agent
  lifetime. `start_session/2` therefore records an optional
  `owner:` pid and monitors it. When the owner exits, the runner
  automatically stops the shell session and drops its monitor
  bookkeeping. A restarted agent gets a fresh shell session id by
  calling `start_session/2` again.

  ## Configuration

  The runner uses `Jido.Shell.ShellSession.start_with_vfs/2` so the
  session runs against the sandboxed in-memory VFS. Worktree-scoped
  VFS remains follow-up work; today each session is isolated from
  every other session by its own in-memory filesystem.

  ## Async command-result contract

  `run_command/2` returns `{:ok, :accepted} | {:error, _}`. The
  actual command result (stdout, stderr, exit_code) is delivered
  asynchronously as a `:command_finished` message to the
  registered process.
  """

  use GenServer

  alias Jido.Shell.ShellSession

  @default_manager __MODULE__
  @type session_id :: String.t()
  @type manager :: pid() | atom()
  @type owner_opt :: {:owner, pid()} | {:owner, nil}

  @doc """
  Start the lifecycle manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @impl true
  def init(state), do: {:ok, state}

  @doc """
  Start a new shell session with a unique id. When `owner:` is
  provided, the session is automatically stopped when that pid
  exits.
  """
  @spec start_session(String.t(), keyword()) :: {:ok, session_id()} | {:error, term()}
  def start_session(prefix, opts \\ []) when is_binary(prefix) do
    session_id = "#{prefix}-#{:erlang.unique_integer([:positive])}"
    owner = Keyword.get(opts, :owner)
    manager = Keyword.get(opts, :manager, @default_manager)

    with {:ok, actual_session_id} <- ShellSession.start_with_vfs(session_id),
         :ok <- register_owner(manager, actual_session_id, owner) do
      {:ok, actual_session_id}
    end
  end

  @doc """
  Async-dispatch a single shell command in the given session.
  """
  @spec run_command(session_id(), String.t()) :: {:ok, :accepted} | {:error, term()}
  def run_command(session_id, command) when is_binary(session_id) and is_binary(command) do
    Jido.Shell.ShellSessionServer.run_command(session_id, command)
  end

  @doc """
  Stop a session and free its resources.
  """
  @spec stop_session(session_id(), keyword()) :: :ok | {:error, term()}
  def stop_session(session_id, opts \\ []) when is_binary(session_id) do
    manager = Keyword.get(opts, :manager, @default_manager)
    unregister_owner(manager, session_id)

    case ShellSession.stop(session_id) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Return whether the lifecycle manager still tracks a session.
  """
  @spec tracked?(session_id(), keyword()) :: boolean()
  def tracked?(session_id, opts \\ []) when is_binary(session_id) do
    manager = Keyword.get(opts, :manager, @default_manager)
    GenServer.call(manager, {:tracked?, session_id})
  end

  @impl true
  def handle_call({:register_owner, session_id, owner}, _from, state) do
    {:reply, :ok, put_owner(state, session_id, owner)}
  end

  def handle_call({:unregister_owner, session_id}, _from, state) do
    {:reply, :ok, drop_session(state, session_id)}
  end

  def handle_call({:tracked?, session_id}, _from, state) do
    {:reply, Map.has_key?(state, session_id), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state, fn {_session_id, meta} -> meta.monitor_ref == ref end) do
      {session_id, _meta} ->
        _ = ShellSession.stop(session_id)
        {:noreply, drop_session(state, session_id)}

      nil ->
        {:noreply, state}
    end
  end

  defp register_owner(_manager, _session_id, nil), do: :ok

  defp register_owner(manager, session_id, owner) when is_pid(owner) do
    GenServer.call(manager, {:register_owner, session_id, owner})
  end

  defp unregister_owner(manager, session_id) when is_pid(manager) do
    if Process.alive?(manager) do
      GenServer.call(manager, {:unregister_owner, session_id})
    else
      :ok
    end
  end

  defp unregister_owner(manager, session_id) do
    case Process.whereis(manager) do
      pid when is_pid(pid) ->
        GenServer.call(manager, {:unregister_owner, session_id})

      nil ->
        :ok
    end
  end

  defp put_owner(state, session_id, owner) when is_pid(owner) do
    monitor_ref = Process.monitor(owner)
    Map.put(state, session_id, %{owner: owner, monitor_ref: monitor_ref})
  end

  defp drop_session(state, session_id) do
    case Map.pop(state, session_id) do
      {%{monitor_ref: ref}, next_state} ->
        Process.demonitor(ref, [:flush])
        next_state

      {nil, next_state} ->
        next_state
    end
  end
end
