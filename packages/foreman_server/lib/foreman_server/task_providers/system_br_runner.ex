defmodule ForemanServer.TaskProviders.SystemBrRunner do
  @moduledoc """
  Sole `System.cmd("br", ...)` site in the codebase. AC-009 architecture gate
  enforces this — see TRD-031.
  """

  @behaviour ForemanServer.TaskProviders.BrRunner
  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry

  @action_subcommands %{
    ready: "ready",
    show: "show",
    update: "update",
    close: "close",
    where: "where",
    schema: "schema"
  }
  @default_timeout_ms 60_000
  @max_kill_wait_ms 5_000
  @temp_file_leaked_event [:foreman_server, :task_provider, :beads, :temp_file, :leaked]

  @type response :: %{stdout: String.t(), stderr: String.t(), exit_code: integer() | nil}

  @impl true
  def cmd(request, project_config, opts \\ []) when is_list(opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, configured_timeout_ms())
    stdin_payload = fetch_stdin_payload!(opts)
    temp_files = create_temp_files(stdin_payload)

    try do
      argv = build_argv(request, project_config)
      port = open_port(build_shell_command(argv, temp_files))

      try do
        os_pid = get_os_pid!(port)
        monitor_ref = :erlang.monitor(:port, port)

        try do
          case await_port_completion(port, monitor_ref, timeout_ms) do
            {:ok, stdout, exit_code} ->
              finalize_result(stdout, temp_files, exit_code)

            {:timeout, stdout} ->
              exit_code = terminate_os_process(os_pid)
              stdout = await_port_exit_after_timeout(port, monitor_ref, stdout)
              finalize_timeout(stdout, temp_files, exit_code)

            {:down, reason, stdout} ->
              stderr = read_temp_file(temp_files.stderr)
              cleanup_temp_files(temp_files)

              {:error,
               %{
                 stdout: stdout,
                 stderr: stderr,
                 exit_code: nil,
                 reason: normalize_down_reason(reason)
               }}
          end
        after
          :erlang.demonitor(monitor_ref, [:flush])
        end
      after
        safe_close_port(port)
      end
    after
      cleanup_leaked_temp_files(temp_files)
    end
  end

  defp build_argv({:schema, _payload} = request, _project_config) do
    {action, payload} = validate_request!(request)
    subcommand = Map.fetch!(@action_subcommands, action)
    action_argv = build_action_argv(action, payload)

    ["br", subcommand | action_argv]
  end

  defp build_argv(request, project_config) do
    {action, payload} = validate_request!(request)
    database_path = fetch_database_path!(project_config)
    subcommand = Map.fetch!(@action_subcommands, action)
    action_argv = build_action_argv(action, payload)

    ["br", subcommand, "--db", database_path | action_argv]
  end

  defp validate_request!({action, payload}) when is_atom(action) and is_map(payload) do
    unless Map.has_key?(@action_subcommands, action) do
      raise ArgumentError, "unknown br action: #{inspect(action)}"
    end

    {action, payload}
  end

  defp validate_request!(request) do
    raise ArgumentError,
          "expected request as {:atom_action, payload_map}, got: #{inspect(request)}"
  end

  defp fetch_database_path!(%{database_path: database_path}) when is_binary(database_path),
    do: database_path

  defp fetch_database_path!(%{"database_path" => database_path}) when is_binary(database_path),
    do: database_path

  defp fetch_database_path!(project_config) do
    raise ArgumentError,
          "expected project_config with binary :database_path, got: #{inspect(project_config)}"
  end

  defp build_action_argv(:schema, payload) do
    validate_payload_shape!(:schema, payload)

    [fetch_optional(payload, :schema)]
    |> maybe_append_json_flag()
  end

  defp build_action_argv(action, payload) do
    payload
    |> extract_flags!()
    |> maybe_prepend_id(action, payload)
    |> maybe_append_json_flag()
    |> tap(fn _ -> validate_payload_shape!(action, payload) end)
  end

  defp validate_payload_shape!(:update, payload) do
    case fetch_optional(payload, :subcommand) do
      nil -> :ok
      subcommand when is_binary(subcommand) -> :ok
      other -> raise ArgumentError, "expected :subcommand to be a binary, got: #{inspect(other)}"
    end
  end

  defp validate_payload_shape!(:schema, payload) do
    case fetch_optional(payload, :schema) do
      schema when is_binary(schema) and schema != "" ->
        :ok

      other ->
        raise ArgumentError, "expected :schema to be a non-empty binary, got: #{inspect(other)}"
    end
  end

  defp validate_payload_shape!(_action, payload) do
    case fetch_optional(payload, :database_path) do
      nil ->
        :ok

      database_path when is_binary(database_path) ->
        :ok

      other ->
        raise ArgumentError, "expected :database_path to be a binary, got: #{inspect(other)}"
    end
  end

  defp extract_flags!(payload) do
    case fetch_optional(payload, :flags) do
      nil ->
        []

      flags when is_list(flags) ->
        if Enum.all?(flags, &is_binary/1) do
          flags
        else
          raise ArgumentError, "expected :flags to be a list of binaries, got: #{inspect(flags)}"
        end

      other ->
        raise ArgumentError, "expected :flags to be a list of binaries, got: #{inspect(other)}"
    end
  end

  defp maybe_prepend_id(flags, action, payload) when action in [:show, :close] do
    case fetch_optional(payload, :id) do
      id when is_binary(id) and id != "" ->
        if Enum.member?(flags, id), do: flags, else: [id | flags]

      nil ->
        flags

      other ->
        raise ArgumentError, "expected :id to be a non-empty binary, got: #{inspect(other)}"
    end
  end

  defp maybe_prepend_id(flags, _action, _payload), do: flags

  defp maybe_append_json_flag(flags) do
    if Enum.member?(flags, "--json"), do: flags, else: flags ++ ["--json"]
  end

  defp build_shell_command(argv, temp_files) do
    stdin_redirect =
      case temp_files.stdin do
        nil -> " < /dev/null"
        %{path: path} -> " < " <> shell_quote(path)
      end

    stderr_redirect =
      case temp_files.stderr do
        nil -> ""
        %{path: path} -> " 2> " <> shell_quote(path)
      end

    "exec " <> Enum.map_join(argv, " ", &shell_quote/1) <> stdin_redirect <> stderr_redirect
  end

  defp open_port(shell_command) do
    Port.open({:spawn_executable, "/bin/sh"}, [:binary, :exit_status, args: ["-c", shell_command]])
  end

  defp get_os_pid!(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      nil -> raise "failed to capture OS PID from port"
    end
  end

  defp await_port_completion(port, monitor_ref, timeout_ms) do
    deadline_ms = System.monotonic_time(:millisecond) + normalize_timeout_ms(timeout_ms)
    receive_port_messages(port, monitor_ref, [], deadline_ms)
  end

  defp receive_port_messages(port, monitor_ref, chunks, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        receive_port_messages(port, monitor_ref, [data | chunks], deadline_ms)

      {^port, {:exit_status, exit_code}} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), exit_code}

      {:DOWN, ^monitor_ref, :port, ^port, reason} ->
        {:down, reason, IO.iodata_to_binary(Enum.reverse(chunks))}
    after
      remaining_ms ->
        {:timeout, IO.iodata_to_binary(Enum.reverse(chunks))}
    end
  end

  defp await_port_exit_after_timeout(port, monitor_ref, stdout) do
    case receive_port_messages(
           port,
           monitor_ref,
           [stdout],
           System.monotonic_time(:millisecond) + @max_kill_wait_ms
         ) do
      {:ok, stdout_after_kill, _exit_code} -> stdout_after_kill
      {:down, _reason, stdout_after_kill} -> stdout_after_kill
      {:timeout, stdout_after_kill} -> stdout_after_kill
    end
  end

  defp terminate_os_process(os_pid) when is_integer(os_pid) do
    if process_exists?(os_pid) do
      run_kill(os_pid, "-TERM")

      if wait_for_exit(os_pid, @max_kill_wait_ms) do
        143
      else
        run_kill(os_pid, "-KILL")
        wait_for_exit(os_pid, @max_kill_wait_ms)
        137
      end
    end
  end

  defp process_exists?(os_pid) when is_integer(os_pid) do
    case :os.cmd(~c"kill -0 #{os_pid}") do
      [] -> true
      _ -> false
    end
  end

  defp run_kill(os_pid, signal) when is_integer(os_pid) and is_binary(signal) do
    :os.cmd(String.to_charlist("kill #{signal} #{os_pid}"))
    :ok
  end

  defp wait_for_exit(_os_pid, 0), do: false

  defp wait_for_exit(os_pid, timeout_ms) when timeout_ms > 0 do
    if process_exists?(os_pid) do
      Process.sleep(100)
      wait_for_exit(os_pid, max(timeout_ms - 100, 0))
    else
      true
    end
  end

  defp finalize_result(stdout, temp_files, 0) do
    stderr = read_temp_file(temp_files.stderr)
    cleanup_temp_files(temp_files)
    {:ok, %{stdout: stdout, stderr: stderr, exit_code: 0}}
  end

  defp finalize_result(stdout, temp_files, exit_code) do
    stderr = read_temp_file(temp_files.stderr)
    cleanup_temp_files(temp_files)
    {:error, %{stdout: stdout, stderr: stderr, exit_code: exit_code}}
  end

  defp finalize_timeout(stdout, temp_files, exit_code) do
    stderr = read_temp_file(temp_files.stderr)
    cleanup_temp_files(temp_files)
    {:error, %{stdout: stdout, stderr: stderr, exit_code: exit_code, reason: :timeout}}
  end

  defp create_temp_files(stdin_payload) do
    stderr_file = create_temp_file!(:stderr, "")

    try do
      %{
        stderr: stderr_file,
        stdin: create_optional_stdin_temp_file(stdin_payload)
      }
    rescue
      error ->
        delete_temp_file(stderr_file)
        reraise error, __STACKTRACE__
    end
  end

  defp create_optional_stdin_temp_file(nil), do: nil

  defp create_optional_stdin_temp_file(payload) when is_binary(payload) do
    create_temp_file!(:stdin, payload)
  end

  defp fetch_stdin_payload!(opts) do
    case Keyword.get(opts, :stdin_payload) do
      payload when is_binary(payload) ->
        payload

      nil ->
        nil

      other ->
        raise ArgumentError, "expected :stdin_payload to be a binary, got: #{inspect(other)}"
    end
  end

  defp create_temp_file!(kind, contents) when is_binary(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "system_br_runner_#{kind}_#{System.unique_integer([:positive, :monotonic])}.tmp"
      )

    try do
      File.write!(path, contents, [:write, :exclusive])
      File.chmod!(path, 0o600)
      %{kind: kind, path: path}
    rescue
      error ->
        File.rm(path)
        reraise error, __STACKTRACE__
    end
  end

  defp read_temp_file(nil), do: ""

  defp read_temp_file(%{path: path}) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, :enoent} -> ""
      {:error, reason} -> raise "failed to read temp file #{path}: #{inspect(reason)}"
    end
  end

  defp cleanup_temp_files(temp_files) do
    temp_files
    |> Map.values()
    |> Enum.each(&delete_temp_file/1)
  end

  defp delete_temp_file(nil), do: :ok

  defp delete_temp_file(%{path: path}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> raise "failed to delete temp file #{path}: #{inspect(reason)}"
    end
  end

  defp cleanup_leaked_temp_files(temp_files) do
    temp_files
    |> Map.values()
    |> Enum.each(fn temp_file ->
      case temp_file do
        nil ->
          :ok

        %{kind: kind, path: path} ->
          if File.exists?(path) do
            TaskProviderTelemetry.emit(@temp_file_leaked_event, %{count: 1}, %{kind: kind})
            File.rm(path)
          end
      end
    end)
  end

  defp normalize_down_reason(:normal), do: :port_closed
  defp normalize_down_reason(reason), do: reason

  defp shell_quote(arg) when is_binary(arg) do
    if Regex.match?(~r/\A[A-Za-z0-9_.\/@-]+\z/, arg) do
      arg
    else
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    end
  end

  defp safe_close_port(port) do
    try do
      Port.close(port)
      :ok
    catch
      :error, :badarg -> :ok
    end
  end

  defp configured_timeout_ms do
    Application.get_env(:foreman_server, __MODULE__, [])[:timeout_ms] || @default_timeout_ms
  end

  defp normalize_timeout_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0,
    do: timeout_ms

  defp normalize_timeout_ms(timeout_ms) do
    raise ArgumentError,
          "expected timeout_ms to be a non-negative integer, got: #{inspect(timeout_ms)}"
  end

  defp fetch_optional(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
