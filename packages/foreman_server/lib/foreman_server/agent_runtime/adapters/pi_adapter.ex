defmodule ForemanServer.AgentRuntime.Adapters.PiAdapter do
  @moduledoc """
  Pi CLI adapter wrapping the local `pi` binary as an Erlang Port.

  This adapter implements the `BackendAdapter` behaviour and owns the Port
  lifecycle including OS-PID capture, safe termination, and temp file cleanup.

  - `executable`: Path to the `pi` binary. Bare names (the default `"pi"`)
    are resolved via `System.find_executable/1` against `PATH`; absolute
    paths are used as-is. (default: `"pi"`)
  - `timeout_ms`: Default timeout in milliseconds (default: `60_000`)

  Both can be overridden via `Application.put_env/4` or per-call via `opts`.
  """

  @behaviour ForemanServer.AgentRuntime.BackendAdapter

  alias ForemanServer.Telemetry

  # Fixed argv fragments
  @pi_argv ["--print", "--mode", "text", "--no-session", "--no-context-files"]

  # Request file headers
  @request_prompt_header "# Prompt"
  @request_context_header "# Context (JSON)"

  @default_executable "pi"
  @default_timeout_ms 60_000
  @max_kill_wait_ms 5_000

  @impl true
  def name, do: :pi

  @impl true
  def capabilities do
    %{
      type: :cli,
      strengths: [:code_generation, :analysis, :tool_use],
      weaknesses: [:long_running_tasks, :batch_processing],
      supported_contexts: [:code, :markdown, :json],
      cost_per_call: 0.0,
      typical_latency_ms: 30_000
    }
  end

  @impl true
  def available? do
    executable()
    |> resolve_executable()
    |> case do
      nil -> false
      path -> executable_file?(path)
    end
  end

  @impl true
  def execute(request, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, timeout())
    raw_executable = Keyword.get(opts, :executable, executable())

    start_time = System.monotonic_time(:microsecond)
    emit_start(start_time)

    result =
      case resolve_executable(raw_executable) do
        nil ->
          {:error, {:enoent, raw_executable}}

        resolved ->
          do_execute(request, resolved, timeout_ms)
      end

    stop_time = System.monotonic_time(:microsecond)
    duration_us = stop_time - start_time

    case result do
      {:ok, _, _} ->
        emit_stop(duration_us, :ok)

      {:error, reason} ->
        status = status_from_reason(reason)
        emit_stop(duration_us, status)
    end

    result
  end

  defp do_execute(request, executable, timeout_ms) when is_binary(executable) do
    # The shell wrapper (see comment near Port.open below) means a missing
    # executable no longer surfaces as `:enoent` from Port.open/2 — `/bin/sh`
    # itself always exists and exits non-zero instead. So check file presence
    # up front and short-circuit with the same `{:enoent, _}` error shape that
    # callers already pattern-match on.
    unless executable_file?(executable) do
      {:error, {:enoent, executable}}
    else
      do_execute_port(request, executable, timeout_ms)
    end
  end

  defp do_execute_port(request, executable, timeout_ms) do
    # Create temp directory first - cleanup happens in outer try/after
    tmp_dir = mk_tmp_dir!()

    try do
      # Build request file with byte-exact framing:
      request_file = Path.join(tmp_dir, "request.txt")
      context_json = Jason.encode!(request.context)

      request_content = <<
        @request_prompt_header::binary,
        "\n\n",
        request.prompt::binary,
        "\n\n",
        @request_context_header::binary,
        "\n\n",
        context_json::binary,
        "\n"
      >>

      # Write with mode 0600 - use exclusive + explicit chmod
      :file.write_file(request_file, request_content, [:write, :exclusive])
      File.chmod!(request_file, 0o600)
      argv = @pi_argv ++ ["@" <> request_file]

      # Spawn via `/bin/sh -c "exec <exe> <args> < /dev/null 2>/dev/null"` so:
      #   1. stdin is explicitly redirected from /dev/null — pi is a Node.js
      #      CLI that hangs waiting for stdin EOF when invoked without it
      #      (Erlang's spawn_executable inherits a live stdin pipe by default).
      #   2. `exec` replaces the shell process with the target binary, so the
      #      OS-PID captured from Port.info/2 is the actual pi process. The
      #      existing kill_os_process!/1 escalation path then targets pi
      #      directly without leaving a shell wrapper as an orphan.
      #   3. stderr is redirected to /dev/null (not folded into stdout) so
      #      that noisy `pi` diagnostics (`[pi-yaml-hooks] ...`, TUI init
      #      messages) never leak into the returned payload — PRD AC-003-1
      #      requires the adapter to return the final text result only.
      sh_cmd =
        "exec " <>
          shell_quote(executable) <>
          " " <>
          Enum.map_join(argv, " ", &shell_quote/1) <>
          " < /dev/null 2>/dev/null"

      # Open port - cleanup happens in inner try/after
      port =
        try do
          Port.open(
            {:spawn_executable, "/bin/sh"},
            [:binary, :exit_status, args: ["-c", sh_cmd]]
          )
        catch
          :error, :enoent ->
            # Executable not found - return error without crashing
            {:error, {:enoent, executable}}
        end

      case port do
        {:error, reason} ->
          {:error, reason}

        port ->
          try do
            os_pid = get_os_pid!(port)

            case wait_for_port(port, timeout_ms) do
              {:ok, output, exit_status} when exit_status == 0 ->
                # Real `pi` interleaves a BEL and trailing TUI cleanup
                # CSI sequences with the user-visible text. Those are
                # terminal-control artifacts, not final text — strip them
                # before returning so PRD AC-003-1's "final text result"
                # contract holds even for noisy emitters.
                {:ok, normalize_output(output), %{}}

              {:ok, _output, exit_status} when exit_status != 0 ->
                {:error, {:non_zero_exit, exit_status}}

              {:error, :timeout} ->
                kill_os_process!(os_pid)
                {:error, :timeout}
            end
          after
            safe_close_port(port)
          end
      end
    after
      File.rm_rf!(tmp_dir)
    end
  end

  defp get_os_pid!(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> raise "Failed to capture OS PID from port"
    end
  end

  defp wait_for_port(port, timeout_ms) do
    receive_loop(port, "", timeout_ms, :erlang.system_time(:millisecond))
  end

  defp receive_loop(port, acc, timeout_ms, start_ms) do
    elapsed = :erlang.system_time(:millisecond) - start_ms
    remaining = timeout_ms - elapsed

    receive do
      {^port, {:data, data}} ->
        receive_loop(port, acc <> data, timeout_ms, start_ms)

      {^port, {:exit_status, exit_status}} ->
        {:ok, acc, exit_status}
    after
      remaining ->
        {:error, :timeout}
    end
  end

  # OS Process termination with escalation
  defp kill_os_process!(os_pid) when is_integer(os_pid) do
    pid_str = Integer.to_string(os_pid)

    # Check if process exists with kill -0
    if process_exists?(os_pid) do
      Process.sleep(100)

      # Try SIGTERM first
      run_kill(pid_str, "-TERM")

      # Wait bounded time for graceful termination
      wait_for_exit(os_pid, @max_kill_wait_ms) ||
        (run_kill(pid_str, "-KILL") && wait_for_exit(os_pid, @max_kill_wait_ms))
    end
  end

  defp process_exists?(pid) when is_integer(pid) do
    case :os.cmd(~c"kill -0 #{pid}") do
      [] -> true
      _ -> false
    end
  end

  defp run_kill(pid_str, sig) do
    :os.cmd(String.to_charlist("kill #{sig} #{pid_str}"))
    :ok
  end

  defp wait_for_exit(_pid, 0), do: false

  defp wait_for_exit(pid, timeout_ms) do
    if process_exists?(pid) do
      Process.sleep(100)
      wait_for_exit(pid, timeout_ms - 100)
    else
      true
    end
  end

  # Safe port close - idempotent and ArgumentError-safe
  @doc """
  Safely closes a port, handling the case where it's already closed.

  This is the single call site for Port.close/1 in this adapter,
  making it easy to reason about port lifecycle.
  """
  @spec safe_close_port(port :: port()) :: :ok
  def safe_close_port(port) do
    try do
      Port.close(port)
      :ok
    catch
      :error, :badarg -> :ok
    end
  end

  # Temp directory creation with mode 0700
  defp mk_tmp_dir! do
    path = Path.join(System.tmp_dir!(), "pi_adapter_#{:rand.uniform(999_999_999)}")
    # Create directory then set mode to 0700 (owner only)
    case File.mkdir(path) do
      :ok ->
        File.chmod!(path, 0o700)
        path

      # Retry on collision
      {:error, :eexist} ->
        mk_tmp_dir!()

      {:error, reason} ->
        raise "Failed to create temp dir: #{inspect(reason)}"
    end
  end

  # POSIX single-quote wrapper for an argv element. Single quotes are the only
  # mechanism that suppresses all shell expansion (no $VAR, no glob), so this
  # is the conservative default for paths the user supplies as the
  # `:executable` config. Elements matching a tight safe-char set (no
  # whitespace, no shell metacharacters, no quotes) pass through untouched
  # so the usual case (`/opt/homebrew/bin/pi --print --mode text ...`) stays
  # readable in logs.
  defp shell_quote(arg) when is_binary(arg) do
    if Regex.match?(~r/\A[A-Za-z0-9_.\/@-]+\z/, arg) do
      arg
    else
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    end
  end

  # Strip terminal-control sequences that real `pi` interleaves with its
  # printable text. Three families:
  #   - OSC (`ESC ] ... (BEL | ST)`): operating-system commands.
  #     ANSI control sequences such as bracketed paste mode, alt-screen
  #     teardown, kitty keyboard progressive enhancement, mouse tracking.
  #   - BEL (`\x07`): terminal bell.
  # Each one matches the same shapes pi 0.83 emits at exit; if a future pi
  # release introduces new sequences they will simply survive and need to
  # be added here.
  defp normalize_output(text) when is_binary(text) do
    text
    |> String.replace(~r/\e\][^\x07\e]*(?:\x07|\e\\)/, "")
    |> String.replace(~r/\e\[[\x30-\x3F]*[\x20-\x2F]*[\x40-\x7E]/, "")
    |> String.replace(~r/\x07/, "")
  end

  # Configuration accessors
  defp executable do
    Application.get_env(:foreman_server, __MODULE__, [])[:executable] || @default_executable
  end

  defp timeout do
    Application.get_env(:foreman_server, __MODULE__, [])[:timeout_ms] || @default_timeout_ms
  end

  # Bare executable names ("pi") are resolved through PATH. Absolute paths
  # are passed through unchanged. nil/empty ⇒ unavailable.
  defp resolve_executable(nil), do: nil
  defp resolve_executable(""), do: nil

  defp resolve_executable(path) when is_binary(path) do
    cond do
      Path.type(path) == :absolute -> path
      true -> System.find_executable(path)
    end
  end

  # True iff `path` is a regular file with at least one executable bit set.
  # Satisfies the TRD-004 "exists and is executable" available?/0 AC.
  defp executable_file?(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
      _ -> false
    end
  end

  # Telemetry helpers
  defp emit_start(start_time) do
    Telemetry.execute(
      [:foreman, :agent_runtime, :adapter, :pi, :start],
      %{system_time: start_time},
      %{backend: :pi}
    )
  end

  defp emit_stop(duration_us, status) do
    Telemetry.execute(
      [:foreman, :agent_runtime, :adapter, :pi, :stop],
      %{duration_us: duration_us, status: status},
      %{backend: :pi}
    )
  end

  defp status_from_reason({:non_zero_exit, _}), do: :non_zero_exit
  defp status_from_reason({:enoent, _}), do: :unavailable
  defp status_from_reason(:timeout), do: :timeout
end
