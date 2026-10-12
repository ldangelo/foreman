defmodule ForemanServer.Jobsite.Sandboxes.ExecTimeout do
  @moduledoc """
  Shared `:timeout_ms` enforcement for `Jobsite.SandboxProvider.exec/3`
  implementations. `System.cmd/3` has no native timeout, so this runs the
  command in a `Task` and kills the Task on expiry.

  This is a known-incomplete timeout: `Task.shutdown/2` kills the BEAM
  process running `System.cmd/3`, not necessarily the OS child process it
  spawned (`System.cmd` holds no externally-killable OS pid). If that matters
  for a given provider, switch its `exec/3` to `Port.open/2` with
  `:exit_status`, following `SystemBrRunner`'s precedent
  (`task_providers/system_br_runner.ex:509-513`) — not a dependency.
  """

  @spec run((-> {String.t(), integer()}), timeout() | nil) ::
          {:ok, {String.t(), integer()}} | {:error, :timeout}
  def run(fun, nil), do: {:ok, fun.()}

  def run(fun, timeout_ms) when is_integer(timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
    end
  end
end
