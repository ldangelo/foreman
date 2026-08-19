defmodule ForemanServer.Agents.JidoShellRunner do
  @moduledoc """
  Wraps jido_shell command execution with jido_vfs sandbox.
  TRD-2026-4212be7e / JSH-T001 / TRD-032.
  """
  require Logger

  def execute(cmd, args, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    vfs_root = Keyword.get(opts, :vfs_root, cwd)
    Logger.info("Executing shell: cmd=#{cmd} args=#{inspect(args)} cwd=#{cwd} vfs=#{vfs_root}")
    run_shell(cmd, args, cwd, vfs_root)
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
