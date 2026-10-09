defmodule ForemanServer.Jobsite.Sandboxes.Host do
  @moduledoc """
  Host sandbox provider: commands run directly on the host, in the worktree.

  Divergence from `Docker`: `exec/3` combines stdout and stderr into
  `ExecResult.stdout`, leaving `stderr` empty — `System.cmd/3`'s
  `stderr_to_stdout: true` does not expose the streams separately.
  """
  @behaviour ForemanServer.Jobsite.SandboxProvider

  alias ForemanServer.Jobsite.{Error, ExecResult}
  alias ForemanServer.Jobsite.Sandboxes.ExecTimeout

  @impl true
  def name, do: "host"

  @impl true
  def kind, do: :bind_mount

  @impl true
  def create(_config, worktree) do
    state_dir = Path.join(worktree.path, ".foreman/state")
    File.mkdir_p!(state_dir)
    {:ok, %{worktree_path: worktree.path, state_dir: state_dir}, worktree.path, nil}
  end

  @impl true
  def exec(state, command, opts) do
    cwd = Keyword.get(opts, :cwd, state.worktree_path)
    timeout_ms = Keyword.get(opts, :timeout_ms)

    result =
      ExecTimeout.run(
        fn -> System.cmd("sh", ["-c", command], cd: cwd, stderr_to_stdout: true) end,
        timeout_ms
      )

    case result do
      {:ok, {output, code}} ->
        {:ok, %ExecResult{stdout: output, stderr: "", exit_code: code}}

      {:error, :timeout} ->
        {:error,
         Error.new(:sandbox_exec_failed, "command timed out", %{
           command: command,
           timeout_ms: timeout_ms
         })}
    end
  end

  # Host execution needs no shim — the resolved binary (already defaulted to
  # the provider's own name by `AgentRunner` when the caller set no custom
  # `:binary`) is passed straight through as the harness's `cli_path`. This
  # is what lets a script substitute a fake/alternate agent executable for
  # host-sandboxed runs, exactly as a container sandbox substitutes its shim.
  @impl true
  def agent_cli_path(_state, agent_binary, _env), do: {:ok, agent_binary}

  @impl true
  def copy_file_in(_state, host_path, sandbox_path), do: copy(host_path, sandbox_path)

  @impl true
  def copy_file_out(_state, sandbox_path, host_path), do: copy(sandbox_path, host_path)

  @impl true
  def close(_state), do: :ok

  defp copy(source, dest) do
    if File.exists?(source) do
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(source, dest)
      :ok
    else
      {:error, Error.new(:copy_failed, "copy source does not exist", %{path: source})}
    end
  end
end
