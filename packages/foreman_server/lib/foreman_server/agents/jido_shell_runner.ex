defmodule ForemanServer.Agents.JidoShellRunner do
  @moduledoc """
  Foreman-side runner that delegates to `Jido.Shell.ShellSession`
  (TRD-2026-4212be7e, JSH-T001).

  The Foreman action layer needs a way to execute shell commands
  on behalf of Jido agents, with a sandboxed VFS. Upstream
  `Jido.Shell` provides the in-memory virtual workspace shell with
  the `Jido.Shell.ShellSession` / `Jido.Shell.ShellSessionServer`
  surface; this module is a thin Foreman wrapper so the rest of
  the codebase (e.g. the upcoming JSH-T002 shell-session-lifecycle
  supervision tree, JSH-T003 worktree VFS, and the migrated
  TypeScript-tool actions like a `bash` action) has a single
  Foreman call point.

  ## Configuration

  The runner uses `Jido.Shell.ShellSession.start_with_vfs/2` so the
  session runs against the sandboxed in-memory VFS — JSH-T001's
  literal task. Worktree-scoped VFS lands in JSH-T003; until then
  the runner is intentionally sandboxed to a per-session
  in-memory filesystem.

  ## Async command-result contract

  `run_command/2` returns `{:ok, :accepted} | {:error, _}`. The
  actual command result (stdout, stderr, exit_code) is delivered
  asynchronously as a `:command_finished` message to the
  registered process. Callers monitor for that message themselves
  (or pass a callback via the third argument to
  `ShellSessionServer.run_command/3` — this wrapper does not
  abstract that option yet).

  ## Public API

    - `start_session/1` — start a new sandboxed session, return id
    - `run_command/2` — async-dispatch a command, return ack
    - `stop_session/1` — stop a session, free resources
  """

  alias Jido.Shell.ShellSession

  @doc """
  Start a new shell session with a unique id. Returns
  `{:ok, session_id}` (per Jido.Shell's contract — `start_with_vfs/2`
  returns `{:ok, id}` directly). Uses the sandboxed VFS path
  (`start_with_vfs/2`) so JSH-T001's "jido_vfs sandbox" requirement
  is met.
  """
  @spec start_session(String.t()) :: {:ok, String.t()} | {:error, term()}
  def start_session(prefix) when is_binary(prefix) do
    session_id = "#{prefix}-#{:erlang.unique_integer([:positive])}"
    ShellSession.start_with_vfs(session_id)
  end

  @doc """
  Async-dispatch a single shell command in the given session.

  Returns `{:ok, :accepted}` (Jido.Shell's contract) or
  `{:error, reason}`. The actual command result is delivered
  asynchronously as a `:command_finished` message to the
  registered process — see the moduledoc's "Async command-result
  contract" section.
  """
  @spec run_command(String.t(), String.t()) :: {:ok, :accepted} | {:error, term()}
  def run_command(session_id, command) when is_binary(session_id) and is_binary(command) do
    Jido.Shell.ShellSessionServer.run_command(session_id, command)
  end

  @doc """
  Stop a session and free its resources.
  """
  @spec stop_session(String.t()) :: :ok | {:error, term()}
  def stop_session(session_id) when is_binary(session_id) do
    case ShellSession.stop(session_id) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end
end
