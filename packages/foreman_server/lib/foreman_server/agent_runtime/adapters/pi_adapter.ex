defmodule ForemanServer.AgentRuntime.Adapters.PiAdapter do
  @moduledoc """
  Pi CLI adapter wrapping the local `pi` binary as an Erlang Port.

  This adapter implements the `BackendAdapter` behaviour and owns the Port
  lifecycle including OS-PID capture, safe termination, and temp file cleanup.

  ## Configuration

  - `executable`: Path to the `pi` binary (default: `/opt/homebrew/bin/pi`)
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

  @default_executable "/opt/homebrew/bin/pi"
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
    executable() |> File.regular?()
  end

  @impl true
  def execute(request, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, timeout())
    executable = Keyword.get(opts, :executable, executable())

    start_time = System.monotonic_time(:microsecond)
    emit_start(start_time)

    result = do_execute(request, executable, timeout_ms)

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

  defp do_execute(request, executable, timeout_ms) do
    # Create temp directory first - cleanup happens in outer try/after
    tmp_dir = mk_tmp_dir!()

    try do
      # Build request file with byte-exact framing:
      request_file = Path.join(tmp_dir, "request.txt")
      context_json = Jason.encode!(request.context)
      request_content = <<
        @request_prompt_header::binary, "\n\n",
        request.prompt::binary, "\n\n",
        @request_context_header::binary, "\n\n",
        context_json::binary, "\n"
      >>
      # Write with mode 0600 - use exclusive + explicit chmod
      :file.write_file(request_file, request_content, [:write, :exclusive])
      File.chmod!(request_file, 0o600)
      argv = @pi_argv ++ ["@" <> request_file]

      # Open port - cleanup happens in inner try/after
      port =
        try do
          Port.open({:spawn_executable, executable}, [:binary, :exit_status, args: argv])
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
                case Jason.decode(output) do
                  {:ok, %{"output" => content}} ->
                    {:ok, content, %{}}
                  {:ok, %{"error" => error}} ->
                    {:error, {:adapter_error, error}}
                  {:ok, other} ->
                    {:error, {:invalid_response, other}}
                  {:error, parse_error} ->
                    {:error, {:parse_error, parse_error}}
                end

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
    after remaining ->
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

      {:error, :eexist} -> mk_tmp_dir!() # Retry on collision

      {:error, reason} -> raise "Failed to create temp dir: #{inspect(reason)}"
    end
  end

  # Configuration accessors
  defp executable do
    Application.get_env(:foreman_server, __MODULE__, [])[:executable] || @default_executable
  end

  defp timeout do
    Application.get_env(:foreman_server, __MODULE__, [])[:timeout_ms] || @default_timeout_ms
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
  defp status_from_reason({:adapter_error, _}), do: :adapter_error
  defp status_from_reason({:parse_error, _}), do: :adapter_error
  defp status_from_reason({:invalid_response, _}), do: :adapter_error
  defp status_from_reason({:enoent, _}), do: :unavailable
  defp status_from_reason(:timeout), do: :timeout

end
