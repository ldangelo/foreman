defmodule ForemanServer.Jobsite.Hooks do
  @moduledoc """
  Setup hooks run around sandbox creation, in order: `host.on_worktree_ready`
  -> sandbox create -> `host.on_sandbox_ready` -> `sandbox.on_sandbox_ready`.

  A non-zero exit aborts the jobsite with `:hook_failed` — unlike
  `Jobsite.Sandbox.exec/3`, a hook failure is fatal, because hooks are setup,
  not caller-driven data a script inspects.

  Shape: `%{host: %{on_worktree_ready: [%{command: s}], on_sandbox_ready: [%{command: s}]},
  sandbox: %{on_sandbox_ready: [%{command: s}]}}`. `sandbox.on_worktree_ready`
  is invalid — the sandbox does not exist at that point — and is rejected by
  `validate/1`.
  """

  alias ForemanServer.Jobsite.{Error, ExecResult, Sandbox}

  @spec validate(map() | nil) :: :ok | {:error, Error.t()}
  def validate(nil), do: :ok

  def validate(hooks) do
    case get_in(hooks, [:sandbox, :on_worktree_ready]) do
      nil ->
        :ok

      [] ->
        :ok

      _entries ->
        {:error,
         Error.new(
           :hook_failed,
           "sandbox.on_worktree_ready is invalid — the sandbox does not exist at that point",
           %{}
         )}
    end
  end

  @spec run_host(map() | nil, atom(), String.t()) :: :ok | {:error, Error.t()}
  def run_host(hooks, phase, cwd) do
    hooks
    |> entries(:host, phase)
    |> run_entries(fn cmd ->
      case System.cmd("sh", ["-c", cmd], cd: cwd, stderr_to_stdout: true) do
        {output, code} -> {:ok, code, output}
      end
    end)
  end

  @spec run_sandbox(map() | nil, atom(), Sandbox.t()) :: :ok | {:error, Error.t()}
  def run_sandbox(hooks, phase, sandbox) do
    hooks
    |> entries(:sandbox, phase)
    |> run_entries(fn cmd ->
      case Sandbox.exec(sandbox, cmd) do
        {:ok, %ExecResult{exit_code: code, stdout: output}} -> {:ok, code, output}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp entries(nil, _target, _phase), do: []
  defp entries(hooks, target, phase), do: hooks |> Map.get(target, %{}) |> Map.get(phase, [])

  defp run_entries(entries, exec_fun) do
    Enum.reduce_while(entries, :ok, fn %{command: cmd}, :ok ->
      case exec_fun.(cmd) do
        {:ok, 0, _output} ->
          {:cont, :ok}

        {:ok, code, output} ->
          {:halt,
           {:error,
            Error.new(:hook_failed, "hook exited non-zero", %{
              command: cmd,
              exit_code: code,
              output: output
            })}}

        {:error, reason} ->
          {:halt,
           {:error,
            Error.new(:hook_failed, "hook failed to run", %{command: cmd, reason: reason})}}
      end
    end)
  end
end
