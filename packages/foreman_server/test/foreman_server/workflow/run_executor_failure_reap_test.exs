defmodule ForemanServer.Workflow.RunExecutorFailureReapTest do
  @moduledoc """
  foreman-zmhzw. Real processes: a port-spawned `sh` plays the erlexec exec-port
  that parents the agent; SIGKILL on it (server alive) re-parents the agent to
  pid 1 and closes the port, which is exactly how a run fails `:port_closed`.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.RunExecutor

  @moduletag :tmp_dir

  defp state(dir) do
    %{
      run_id: "run-reap-#{System.unique_integer([:positive])}",
      run_worktree: %{worktree_path: dir, cleanup: :never}
    }
  end

  # An agent (`sleep`, cwd inside `dir`) whose exec-port (`sh`) has been killed.
  defp orphaned_agent(dir) do
    marker = "3#{System.unique_integer([:positive])}"

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        args: ["-c", "cd \"$1\" && sleep #{marker}; :", "sh", dir]
      ])

    agent = await_pid("sleep #{marker}")
    {:os_pid, exec_port} = Port.info(port, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(agent)], stderr_to_stdout: true)
    end)

    System.cmd("kill", ["-9", Integer.to_string(exec_port)])
    await_orphaned(agent)
    agent
  end

  defp await_pid(command, tries \\ 200) do
    {out, _} = System.cmd("pgrep", ["-f", "^" <> command <> "$"], stderr_to_stdout: true)

    case Integer.parse(String.trim(out)) do
      {pid, _} ->
        pid

      :error when tries > 0 ->
        Process.sleep(20)
        await_pid(command, tries - 1)

      :error ->
        flunk("process #{inspect(command)} never appeared")
    end
  end

  defp await_orphaned(pid, tries \\ 200) do
    {out, _} = System.cmd("ps", ["-o", "ppid=", "-p", Integer.to_string(pid)])

    cond do
      String.trim(out) == "1" ->
        :ok

      tries > 0 ->
        Process.sleep(20)
        await_orphaned(pid, tries - 1)

      true ->
        flunk("agent #{pid} never re-parented to pid 1")
    end
  end

  defp alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> not String.starts_with?(String.trim(out), "Z")
      _ -> false
    end
  end

  test "a failed run reaps the agent its dead exec-port orphaned", %{tmp_dir: dir} do
    agent = orphaned_agent(dir)
    assert alive?(agent)

    RunExecutor.__cleanup_run_worktree_for_test__(state(dir), :failure)

    refute alive?(agent)
  end

  test "a successful run does not run the reaper", %{tmp_dir: dir} do
    agent = orphaned_agent(dir)

    RunExecutor.__cleanup_run_worktree_for_test__(state(dir), :success)

    assert alive?(agent)
  end

  test "an orphan outside the run's worktree survives a failed run", %{tmp_dir: dir} do
    mine = Path.join(dir, "mine")
    other = Path.join(dir, "mine-other")
    File.mkdir_p!(mine)
    File.mkdir_p!(other)
    agent = orphaned_agent(other)

    RunExecutor.__cleanup_run_worktree_for_test__(state(mine), :failure)

    assert alive?(agent)
  end
end
