defmodule ForemanServer.TaskProviders.SystemKataRunner do
  @moduledoc """
  Sole `kata` subprocess site in `lib/foreman_server/` (REQ-004 architecture gate).

  Every argument is POSIX shell-quoted into one `exec` command line run by
  `/bin/sh`, so the CLI receives each `argv` element unchanged and a task title
  containing shell metacharacters cannot alter the command (AC-008-1). The shell
  exists only to redirect stderr into a private temp file and stdin from
  `/dev/null`; stderr text is never read, only its byte count is reported.

  A call that exceeds `:timeout_ms` (default #{30_000} ms) kills the whole
  process tree: SIGTERM first, SIGKILL after a #{5_000} ms grace period
  (AC-008-2), and returns the retryable `BR_TIMEOUT_SUBPROCESS` error. The temp
  file is removed on every path (AC-008-3). The OS pid of the spawned child is
  emitted on the `[:foreman_server, :task_provider, :kata, :subprocess, :spawned]`
  telemetry event for diagnosis; no output text is attached (AC-008-4).

  Return shape (`ForemanServer.TaskProviders.KataRunner`): `{:ok, stdout}` on
  exit status 0. Every failure is a `ProviderError` built by
  `KataAdapter.BuildProviderError`, the single construction site (AC-007-4), so its
  context is that module's closed key set with `command` (`%{binary: "kata"}`),
  `exit_code` and `stderr_byte_count` filled in:

    * timeout -> `BR_TIMEOUT_SUBPROCESS`, retryable, `exit_code: nil`.
    * missing working directory -> `WORKSPACE_NOT_FOUND`, not retryable.
    * non-zero exit (including death by signal) -> `BR_ERROR_ENVELOPE`, not
      retryable, `exit_code` carries the status. Kata's per-error mapping
      (exit 3/4/5/7/8) is the adapter's job, keyed on that exit code.
    * the port closing without an exit status -> `BR_ERROR_ENVELOPE`,
      `exit_code: nil`.
  """

  @behaviour ForemanServer.TaskProviders.KataRunner

  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.KataAdapter.BuildProviderError

  @binary "kata"
  @default_timeout_ms 30_000
  @max_kill_wait_ms 5_000
  @spawned_event [:foreman_server, :task_provider, :kata, :subprocess, :spawned]

  @impl true
  def cmd(argv, cwd, opts \\ []) do
    validate_argv!(argv)
    validate_cwd!(cwd)
    timeout_ms = opts |> Keyword.validate!(timeout_ms: @default_timeout_ms) |> fetch_timeout_ms!()

    if File.dir?(cwd) do
      run(argv, cwd, timeout_ms)
    else
      {:error,
       build_error(
         "WORKSPACE_NOT_FOUND",
         "Kata working directory does not exist.",
         "Verify the project path before retrying.",
         nil,
         0
       )}
    end
  end

  defp run(argv, cwd, timeout_ms) do
    stderr_path = new_stderr_path()

    try do
      create_stderr_file!(stderr_path)
      port = open_port(build_shell_command(argv, stderr_path), cwd)

      try do
        os_pid = get_os_pid(port)
        emit_spawned(os_pid)
        monitor_ref = Port.monitor(port)

        try do
          case await_port_completion(port, monitor_ref, timeout_ms) do
            {:ok, stdout, 0} ->
              {:ok, stdout}

            {:ok, _stdout, exit_code} ->
              {:error,
               build_error(
                 "BR_ERROR_ENVELOPE",
                 "Kata CLI exited with a non-zero status.",
                 nil,
                 exit_code,
                 stderr_byte_count(stderr_path)
               )}

            :timeout ->
              terminate_os_process(os_pid)
              await_port_exit(port, monitor_ref)

              {:error,
               build_error(
                 "BR_TIMEOUT_SUBPROCESS",
                 "Kata command timed out while the subprocess was running.",
                 "Retry the command after checking Kata responsiveness.",
                 nil,
                 stderr_byte_count(stderr_path)
               )}

            :down ->
              {:error,
               build_error(
                 "BR_ERROR_ENVELOPE",
                 "Kata CLI port closed without an exit status.",
                 nil,
                 nil,
                 stderr_byte_count(stderr_path)
               )}
          end
        after
          Port.demonitor(monitor_ref, [:flush])
        end
      after
        close_port(port)
      end
    after
      File.rm(stderr_path)
    end
  end

  defp validate_argv!(argv) do
    unless is_list(argv) and Enum.all?(argv, &is_binary/1) do
      raise ArgumentError, "expected argv to be a list of binaries, got: #{inspect(argv)}"
    end
  end

  defp validate_cwd!(cwd) do
    unless is_binary(cwd) and cwd != "" do
      raise ArgumentError, "expected cwd to be a non-empty binary, got: #{inspect(cwd)}"
    end
  end

  defp fetch_timeout_ms!(opts) do
    case Keyword.fetch!(opts, :timeout_ms) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms >= 0 ->
        timeout_ms

      other ->
        raise ArgumentError,
              "expected :timeout_ms to be a non-negative integer, got: #{inspect(other)}"
    end
  end

  # Retryability is the `CodeMap` row's, not an argument: BR_TIMEOUT_SUBPROCESS is retryable.
  defp build_error(code, message, hint, exit_code, stderr_byte_count) do
    code
    |> ProviderErrorInput.from_local(message, hint, false)
    |> BuildProviderError.build_provider_error(exit_code, stderr_byte_count)
  end

  defp build_shell_command(argv, stderr_path) do
    "exec " <>
      Enum.map_join([@binary | argv], " ", &shell_quote/1) <>
      " < /dev/null 2> " <> shell_quote(stderr_path)
  end

  defp shell_quote(arg) when is_binary(arg) do
    if Regex.match?(~r/\A[A-Za-z0-9_.\/@-]+\z/, arg) do
      arg
    else
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    end
  end

  defp open_port(shell_command, cwd) do
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      args: ["-c", shell_command],
      cd: cwd
    ])
  end

  # A very short-lived command can exit before this runs; the port is then already
  # gone and `Port.info/2` returns nil. Nothing needs killing for a port that has
  # exited, and `terminate_os_process/1` tolerates a nil pid.
  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      nil -> nil
    end
  end

  defp emit_spawned(nil), do: :ok

  defp emit_spawned(os_pid) when is_integer(os_pid) do
    TaskProviderTelemetry.emit(@spawned_event, %{}, %{os_pid: os_pid})
  end

  defp await_port_completion(port, monitor_ref, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms
    receive_port_messages(port, monitor_ref, [], deadline_ms)
  end

  defp receive_port_messages(port, monitor_ref, chunks, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        receive_port_messages(port, monitor_ref, [data | chunks], deadline_ms)

      {^port, {:exit_status, exit_code}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), exit_code}

      {:DOWN, ^monitor_ref, :port, ^port, _reason} ->
        :down
    after
      remaining_ms -> :timeout
    end
  end

  # After a kill the port closes once the child (and every descendant holding the
  # stdout pipe) is gone. Bounded by the same grace period as the signals.
  defp await_port_exit(port, monitor_ref) do
    receive do
      {^port, {:exit_status, _exit_code}} -> :ok
      {:DOWN, ^monitor_ref, :port, ^port, _reason} -> :ok
    after
      @max_kill_wait_ms -> :ok
    end
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # Nothing to signal when the port had already exited before `get_os_pid/1` ran.
  defp terminate_os_process(nil), do: :ok

  # Signals the whole tree under `os_pid`, not only `os_pid`: a wrapper's children
  # inherit the stdout pipe, so one that outlives the kill keeps the port open and
  # keeps running afterwards. The tree is snapshotted once, before the first signal
  # (a SIGTERMed parent re-parents its children to pid 1, after which `pgrep -P`
  # no longer finds them).
  defp terminate_os_process(os_pid) when is_integer(os_pid) do
    tree = process_tree(os_pid)
    Enum.each(tree, &signal(&1, "-TERM"))

    unless wait_for_all_exit(tree, @max_kill_wait_ms) do
      tree |> Enum.filter(&process_exists?/1) |> Enum.each(&signal(&1, "-KILL"))
      wait_for_all_exit(tree, @max_kill_wait_ms)
    end

    :ok
  end

  # `os_pid` followed by all of its descendants, depth first.
  defp process_tree(os_pid) do
    children =
      case System.cmd("pgrep", ["-P", Integer.to_string(os_pid)], stderr_to_stdout: true) do
        {out, 0} -> out |> String.split() |> Enum.map(&String.to_integer/1)
        {_out, _none_or_error} -> []
      end

    [os_pid | Enum.flat_map(children, &process_tree/1)]
  end

  defp process_exists?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true))
  end

  defp signal(os_pid, signal) do
    System.cmd("kill", [signal, Integer.to_string(os_pid)], stderr_to_stdout: true)
  end

  defp wait_for_all_exit(pids, timeout_ms) when timeout_ms > 0 do
    if Enum.any?(pids, &process_exists?/1) do
      Process.sleep(100)
      wait_for_all_exit(pids, timeout_ms - 100)
    else
      true
    end
  end

  defp wait_for_all_exit(pids, _timeout_ms), do: not Enum.any?(pids, &process_exists?/1)

  defp new_stderr_path do
    Path.join(
      System.tmp_dir!(),
      "system_kata_runner_stderr_#{System.unique_integer([:positive, :monotonic])}_" <>
        "#{System.system_time(:nanosecond)}_#{:rand.uniform(1_000_000)}.tmp"
    )
  end

  defp create_stderr_file!(path) do
    File.write!(path, "", [:write, :exclusive])
    File.chmod!(path, 0o600)
  end

  # Only the size is read: stderr text may carry task content and is never inspected.
  defp stderr_byte_count(path), do: File.stat!(path).size
end
