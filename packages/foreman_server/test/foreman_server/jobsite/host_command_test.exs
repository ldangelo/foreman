defmodule ForemanServer.Jobsite.HostCommandTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Jobsite.HostCommand

  @moduletag :tmp_dir

  test "exit code, merged stderr, cwd and env overlay", %{tmp_dir: dir} do
    assert {:ok, %{exit_code: 3, output: output}} =
             HostCommand.run("echo out; echo err >&2; echo $GREETING; pwd; exit 3", dir,
               env: %{"GREETING" => "hello"}
             )

    assert output =~ "out"
    assert output =~ "err"
    assert output =~ "hello"
    assert output =~ Path.basename(dir)
  end

  test "output is bounded to its tail", %{tmp_dir: dir} do
    assert {:ok, %{exit_code: 0, output: output}} =
             HostCommand.run("i=0; while [ $i -lt 500 ]; do echo line-$i; i=$((i+1)); done", dir,
               max_output_bytes: 100
             )

    assert byte_size(output) <= 100
    assert output =~ "line-499"
    refute output =~ "line-0\n"
  end

  test "a timeout kills the whole process group of the script, not just the shell", %{
    tmp_dir: dir
  } do
    pid_file = Path.join(dir, "grandchild.pid")

    script = "sleep 300 & echo $! > #{pid_file}; echo started; wait"

    assert {:error, {:timeout, output}} = HostCommand.run(script, dir, timeout_ms: 1_500)
    assert output =~ "started"

    grandchild = pid_file |> File.read!() |> String.trim()
    assert eventually_dead?(grandchild), "grandchild #{grandchild} survived the timeout"
  end

  # Dead = gone, or a zombie (killed but not yet reaped: a container whose PID 1
  # does not reap orphans leaves the corpse visible to `kill -0`).
  defp eventually_dead?(pid, attempts \\ 100) do
    if alive?(pid) and attempts > 0 do
      Process.sleep(50)
      eventually_dead?(pid, attempts - 1)
    else
      not alive?(pid)
    end
  end

  defp alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", pid], stderr_to_stdout: true) do
      {out, 0} -> not String.starts_with?(String.trim(out), "Z")
      {_, _} -> false
    end
  end
end
