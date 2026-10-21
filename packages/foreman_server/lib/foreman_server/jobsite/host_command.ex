defmodule ForemanServer.Jobsite.HostCommand do
  @moduledoc """
  Runs one `sh -c` command on the server host with an environment overlay, a
  wall-clock timeout and bounded output (E4-S4).

  The command runs inside its OWN process group, and on timeout the wrapper is
  sent TERM, which trap-kills that whole group. The group is made with `setsid`
  where it exists (Linux: dash's `set -m` creates NO new group without a
  controlling terminal, so `kill -- -PID` then hit nothing and the script's
  children survived) and with `set -m` otherwise (macOS has no `setsid`): no orphan child
  survives a timeout, unlike `System.cmd/3` under `Task.shutdown/2` (see
  `Sandboxes.ExecTimeout`). stderr is merged into stdout. Only the LAST
  `:max_output_bytes` of output are kept, so a chatty script cannot grow the
  BEAM heap without bound.

  Options: `:env` (`%{String.t() => String.t()}` overlaid on the ambient env),
  `:timeout_ms` (`:infinity` default), `:max_output_bytes` (default 65_536).
  """

  @default_max_output 65_536
  @kill_grace_ms 2_000

  # The script is `$1` so it is never interpolated into the wrapper text.
  @wrapper """
  exec 2>/dev/null
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c "$1" 2>&1 &
  else
    set -m
    sh -c "$1" 2>&1 &
  fi
  PID=$!
  trap 'kill -s KILL -- -$PID 2>/dev/null; exit 143' TERM
  wait $PID
  exit $?
  """

  @type result ::
          {:ok, %{exit_code: non_neg_integer(), output: String.t()}}
          | {:error, {:timeout, String.t()}}

  @spec run(String.t(), String.t(), keyword()) :: result()
  def run(command, cwd, opts \\ []) when is_binary(command) and is_binary(cwd) do
    env =
      opts
      |> Keyword.get(:env, %{})
      |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    timeout = Keyword.get(opts, :timeout_ms, :infinity)
    max = Keyword.get(opts, :max_output_bytes, @default_max_output)

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:args, ["-c", @wrapper, "sh", command]},
        {:cd, cwd},
        {:env, env}
      ])

    deadline = if timeout == :infinity, do: :infinity, else: now() + timeout
    collect(port, deadline, "", max)
  end

  defp collect(port, deadline, acc, max) do
    wait = remaining(deadline)

    receive do
      {^port, {:data, data}} ->
        collect(port, deadline, tail(acc <> data, max), max)

      {^port, {:exit_status, code}} ->
        {:ok, %{exit_code: code, output: acc}}
    after
      wait ->
        {:error, {:timeout, kill(port, acc, max)}}
    end
  end

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - now(), 0)

  # TERM the wrapper (its trap kills the process group), drain what remains,
  # and escalate to KILL on the wrapper if it does not exit within the grace.
  defp kill(port, acc, max) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
        acc = drain(port, acc, max, now() + @kill_grace_ms)

        if Port.info(port) != nil do
          _ = System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
          catch_close(port)
        end

        acc

      nil ->
        acc
    end
  end

  defp drain(port, acc, max, deadline) do
    receive do
      {^port, {:data, data}} -> drain(port, tail(acc <> data, max), max, deadline)
      {^port, {:exit_status, _}} -> acc
    after
      remaining(deadline) -> acc
    end
  end

  defp catch_close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp tail(bin, max) when byte_size(bin) > max,
    do: binary_part(bin, byte_size(bin) - max, max)

  defp tail(bin, _max), do: bin

  defp now, do: System.monotonic_time(:millisecond)
end
