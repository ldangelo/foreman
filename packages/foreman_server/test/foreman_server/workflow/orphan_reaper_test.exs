defmodule ForemanServer.Workflow.OrphanReaperTest do
  @moduledoc """
  Real processes, no stubs: an "orphan" is a process whose parent exited, so
  `init` adopted it. `sh -c '( sleep N & )'` produces exactly that.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.OrphanReaper

  @moduletag :tmp_dir

  defp spawn_orphan(dir, marker) do
    {_, 0} =
      System.cmd("sh", [
        "-c",
        "cd \"$1\" && ( exec sleep 3#{marker} </dev/null >/dev/null 2>&1 & )",
        "sh",
        dir
      ])

    pid = await_pid("sleep 3#{marker}")
    on_exit(fn -> System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true) end)
    pid
  end

  # `ps` shows the process as soon as the shell has exec'd it.
  defp await_pid(command, tries \\ 100) do
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

  defp alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)], stderr_to_stdout: true) do
      {out, 0} -> not String.starts_with?(String.trim(out), "Z")
      _ -> false
    end
  end

  test "terminates an orphan whose cwd is inside the worktree", %{tmp_dir: dir} do
    pid = spawn_orphan(dir, System.unique_integer([:positive]))

    assert {:ok, reaped} = OrphanReaper.reap(dir)

    assert pid in Enum.map(reaped, & &1.pid)
    refute alive?(pid)
  end

  test "also terminates what the orphan spawned, even in another process group", %{tmp_dir: dir} do
    marker = System.unique_integer([:positive])
    elsewhere = Path.join(dir, "elsewhere")
    File.mkdir_p!(elsewhere)
    mine = Path.join(dir, "mine")
    File.mkdir_p!(mine)

    # orphan `sh` (cwd inside the worktree) -> child `sleep` (cwd elsewhere, so only
    # reachable as a descendant); `; :` stops sh from exec-ing the child away.
    {_, 0} =
      System.cmd("sh", [
        "-c",
        "cd \"$1\" && ( sh -c '(cd \"$0\" && sleep 3#{marker}); :' \"$2\" </dev/null >/dev/null 2>&1 & )",
        "sh",
        mine,
        elsewhere
      ])

    child = await_pid("sleep 3#{marker}")

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(child)], stderr_to_stdout: true)
    end)

    assert {:ok, [_ | _]} = OrphanReaper.reap(mine)
    refute alive?(child)
  end

  test "terminates an orphan working in a subdirectory of the worktree", %{tmp_dir: dir} do
    sub = Path.join(dir, "nested/deeper")
    File.mkdir_p!(sub)
    pid = spawn_orphan(sub, System.unique_integer([:positive]))

    assert {:ok, [_ | _]} = OrphanReaper.reap(dir)
    refute alive?(pid)
  end

  test "leaves an orphan working in a different directory alone", %{tmp_dir: dir} do
    mine = Path.join(dir, "mine")
    other = Path.join(dir, "mine-other")
    File.mkdir_p!(mine)
    File.mkdir_p!(other)
    pid = spawn_orphan(other, System.unique_integer([:positive]))

    assert {:ok, []} = OrphanReaper.reap(mine)
    assert alive?(pid)
  end

  test "leaves a process that still has a live parent alone", %{tmp_dir: dir} do
    marker = System.unique_integer([:positive])

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        args: ["-c", "cd \"$1\" && sleep 3#{marker}; :", "sh", dir]
      ])

    pid = await_pid("sleep 3#{marker}")

    on_exit(fn ->
      System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      if Port.info(port), do: Port.close(port)
    end)

    assert {:ok, []} = OrphanReaper.reap(dir)
    assert alive?(pid)
  end

  test "reports a worktree with nothing running in it", %{tmp_dir: dir} do
    assert {:ok, []} = OrphanReaper.reap(dir)
  end
end
