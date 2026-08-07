defmodule ForemanServer.CLI.DoctorTaskProvider do
  @moduledoc false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TaskProviders.ProviderError

  @runner Application.compile_env(
            :foreman_server,
            :br_runner,
            ForemanServer.TaskProviders.SystemBrRunner
          )
  @schema_cache_name :foreman_server_json_schema_cache
  @doctor_probe_event [:foreman_server, :task_provider, :beads_adapter, :doctor, :probe]
  @probe_timeout_ms 30_000
  @version_argv ["br", "--version"]

  @type run_result :: :ok | {:error, pos_integer(), String.t()}

  @spec run([String.t()]) :: run_result()
  def run([]) do
    :ok = ensure_schema_cache_started()

    reports =
      ProjectionStore.list_projects()
      |> Enum.filter(&task_provider_project?/1)
      |> Enum.sort_by(&(fetch_value(&1, :project_id) || ""))
      |> Enum.map(&build_project_report/1)

    Enum.each(reports, &IO.puts(Jason.encode!(&1)))

    if Enum.all?(reports, &Map.get(&1, :healthy, false)) do
      :ok
    else
      {:error, 1, "one or more unhealthy task_provider projects"}
    end
  end

  def run(_args), do: {:error, 64, "usage: foreman doctor task_provider"}

  defp build_project_report(project) do
    project_id = fetch_value(project, :project_id)
    task_provider = fetch_value(project, :task_provider)
    provider_ref = fetch_value(task_provider, :provider)
    project_config = fetch_value(task_provider, :config) || %{}
    database_path = project_database_path(project_config)

    with {:ok, provider_module} <-
           route_or_resolve_provider(project_id, database_path, provider_ref),
         capabilities when is_map(capabilities) <- provider_module.capabilities() do
      report = %{
        project_id: project_id,
        healthy: true,
        provider_id: normalize_provider_id(capabilities[:provider_id]),
        contract_version: capabilities[:contract_version],
        br_version: nil,
        capabilities: nil,
        sample_ready: nil,
        schema_validation_failures: []
      }

      cond do
        not is_binary(database_path) or database_path == "" ->
          put_unhealthy(report, %{
            code: "DATABASE_PATH_MISSING",
            message: "task_provider.config.database_path is missing",
            hint: nil,
            exit_code: nil,
            stderr_byte_count: 0,
            redacted_fields: []
          })

        not provider_module.available?() ->
          put_unhealthy(report, %{
            code: "PROVIDER_MISSING",
            message: "br not installed",
            hint: nil,
            exit_code: nil,
            stderr_byte_count: 0,
            redacted_fields: []
          })

        true ->
          probe_project(report, provider_module, project_config, database_path)
      end
    else
      {:error, reason} ->
        %{
          project_id: project_id,
          healthy: false,
          provider_id: normalize_provider_id(provider_ref),
          contract_version: nil,
          br_version: nil,
          capabilities: nil,
          sample_ready: nil,
          schema_validation_failures: [],
          error: %{
            code: "TASK_PROVIDER_NOT_CONFIGURED",
            message: "task_provider could not be resolved",
            hint: inspect(reason),
            exit_code: nil,
            stderr_byte_count: 0,
            redacted_fields: []
          }
        }
    end
  end

  defp probe_project(report, provider_module, project_config, database_path) do
    case preflight_provider(provider_module, database_path) do
      :ok ->
        {report, probe_errors} =
          report
          |> apply_text_probe(:br_version, version_probe())
          |> apply_json_probe(:capabilities, capabilities_probe())
          |> apply_json_probe(:sample_ready, ready_probe(project_config, database_path))

        report = finalize_report(report, probe_errors)

        if report.schema_validation_failures == [] do
          report
        else
          Map.put(report, :healthy, false)
        end

      {:error, error} ->
        put_unhealthy(report, provider_error_map(error))
    end
  end

  defp apply_text_probe({report, errors}, field, {:ok, value}),
    do: {Map.put(report, field, value), errors}

  defp apply_text_probe({report, errors}, _field, {:error, error}),
    do: {report, errors ++ [error]}

  defp apply_text_probe(report, field, result), do: apply_text_probe({report, []}, field, result)

  defp apply_json_probe({report, errors}, field, {:ok, value, failures}) do
    updated_failures = report.schema_validation_failures ++ failures

    {report |> Map.put(field, value) |> Map.put(:schema_validation_failures, updated_failures),
     errors}
  end

  defp apply_json_probe({report, errors}, _field, {:error, error}),
    do: {report, errors ++ [error]}

  defp apply_json_probe(report, field, result), do: apply_json_probe({report, []}, field, result)

  defp finalize_report(report, []), do: report
  defp finalize_report(report, [first_error | _]), do: put_unhealthy(report, first_error)

  defp version_probe do
    emit_probe(@version_argv)

    case @runner.cmd({:version, %{}}, %{}, timeout_ms: @probe_timeout_ms) do
      {:ok, %{stdout: stdout}} ->
        {:ok, String.trim(stdout)}

      {:error, result} ->
        {:error, runner_error_map("BR_VERSION_FAILED", "br --version failed", result)}
    end
  end

  defp capabilities_probe do
    argv = ["br", "capabilities", "--json"]
    emit_probe(argv)

    case @runner.cmd({:capabilities, %{}}, %{}, timeout_ms: @probe_timeout_ms) do
      {:ok, %{stdout: stdout}} ->
        case decode_json(stdout, "commands", "capabilities") do
          {:ok, payload} -> {:ok, payload, validate_commands_payload(payload)}
          {:error, failures} -> {:ok, nil, failures}
        end

      {:error, result} ->
        {:error,
         runner_error_map("BR_CAPABILITIES_FAILED", "br capabilities --json failed", result)}
    end
  end

  defp ready_probe(project_config, database_path) do
    argv = ["br", "ready", "--db", database_path, "--limit", "1", "--json"]
    emit_probe(argv)

    case @runner.cmd({:ready, %{flags: ["--limit", "1"]}}, project_config,
           timeout_ms: @probe_timeout_ms
         ) do
      {:ok, %{stdout: stdout}} ->
        case decode_json(stdout, "ready_issue", "ready") do
          {:ok, payload} -> {:ok, payload, validate_ready_payload(payload)}
          {:error, failures} -> {:ok, nil, failures}
        end

      {:error, result} ->
        {:error, runner_error_map("BR_READY_FAILED", "br ready --limit 1 --json failed", result)}
    end
  end

  defp validate_commands_payload(payload) do
    case JsonSchemaCache.validate(:commands, payload) do
      :ok -> []
      {:error, errors} -> normalize_schema_failures(errors, "capabilities", "commands")
    end
  end

  defp validate_ready_payload(payload) when is_list(payload) do
    payload
    |> Enum.with_index()
    |> Enum.flat_map(fn {issue_payload, index} ->
      validate_ready_issue(issue_payload, [index])
    end)
  end

  defp validate_ready_payload(%{"issues" => issues}) when is_list(issues) do
    validate_ready_payload(issues)
  end

  defp validate_ready_payload(%{issues: issues}) when is_list(issues) do
    validate_ready_payload(issues)
  end

  defp validate_ready_payload(%{} = payload), do: validate_ready_issue(payload, [])

  defp validate_ready_payload(_payload) do
    [
      schema_failure(
        "ready",
        "ready_issue",
        [],
        "sample ready payload must decode to a JSON object or array"
      )
    ]
  end

  defp validate_ready_issue(payload, prefix) do
    case JsonSchemaCache.validate(:ready_issue, payload) do
      :ok -> []
      {:error, errors} -> normalize_schema_failures(errors, "ready", "ready_issue", prefix)
    end
  end

  defp decode_json(stdout, schema_name, probe_name) when is_binary(stdout) do
    case String.trim(stdout) do
      "" ->
        {:error, [schema_failure(probe_name, schema_name, [], "probe returned empty output")]}

      json ->
        case Jason.decode(json) do
          {:ok, payload} ->
            {:ok, payload}

          {:error, _reason} ->
            {:error, [schema_failure(probe_name, schema_name, [], "probe returned invalid JSON")]}
        end
    end
  end

  defp preflight_provider(provider_module, database_path) do
    if function_exported?(provider_module, :preflight_database, 2) do
      provider_module.preflight_database(database_path, timeout_ms: @probe_timeout_ms)
    else
      :ok
    end
  end

  defp route_or_resolve_provider(project_id, database_path, provider_ref) do
    case maybe_route_provider(project_id, database_path) do
      {:ok, provider_module} -> {:ok, provider_module}
      {:error, _reason} -> resolve_provider_module(provider_ref)
    end
  end

  defp maybe_route_provider(project_id, database_path)
       when is_binary(project_id) and project_id != "" and is_binary(database_path) and
              database_path != "" do
    TaskProviderRegistry.route(:reopen, {project_id, database_path})
  end

  defp maybe_route_provider(_project_id, _database_path), do: {:error, :not_routable}

  defp resolve_provider_module(provider_module) when is_atom(provider_module) do
    cond do
      provider_module != nil and Code.ensure_loaded?(provider_module) and
          function_exported?(provider_module, :capabilities, 0) ->
        {:ok, provider_module}

      is_atom(provider_module) ->
        case TaskProviderRegistry.routing_snapshot()[provider_module] do
          module when is_atom(module) -> {:ok, module}
          _ -> {:error, :task_provider_not_configured}
        end
    end
  end

  defp resolve_provider_module(provider_module) when is_binary(provider_module) do
    module = Module.concat([provider_module])

    if Code.ensure_loaded?(module) and function_exported?(module, :capabilities, 0) do
      {:ok, module}
    else
      {:error, :task_provider_not_configured}
    end
  end

  defp resolve_provider_module(_provider_module), do: {:error, :task_provider_not_configured}

  defp ensure_schema_cache_started do
    case Process.whereis(@schema_cache_name) do
      nil ->
        case JsonSchemaCache.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp emit_probe(argv) do
    TaskProviderTelemetry.emit(@doctor_probe_event, %{system_time: System.system_time()}, %{
      argv: argv
    })
  end

  defp task_provider_project?(project) do
    case fetch_value(project, :task_provider) do
      %{} -> true
      _ -> false
    end
  end

  defp project_database_path(config) when is_map(config) do
    fetch_value(config, :database_path)
  end

  defp project_database_path(_config), do: nil

  defp fetch_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp fetch_value(_map, _key), do: nil

  defp normalize_provider_id(provider_id) when is_atom(provider_id),
    do: Atom.to_string(provider_id)

  defp normalize_provider_id(provider_id) when is_binary(provider_id), do: provider_id
  defp normalize_provider_id(_provider_id), do: nil

  defp put_unhealthy(report, error) do
    report
    |> Map.put(:healthy, false)
    |> Map.put(:error, error)
  end

  defp provider_error_map(error) when is_struct(error, ProviderError) do
    %{
      code: error.code,
      message: error.message,
      hint: error.hint,
      retryable?: error.retryable?,
      exit_code: error.context[:exit_code],
      stderr_byte_count: error.context[:stderr_byte_count] || 0,
      redacted_fields: Enum.map(error.context[:redacted_fields] || [], &to_string/1)
    }
  end

  defp runner_error_map(code, message, result) do
    %{
      code: code,
      message: message,
      hint: nil,
      exit_code: Map.get(result, :exit_code),
      stderr_byte_count: byte_size(Map.get(result, :stderr, "") || ""),
      redacted_fields: []
    }
  end

  defp normalize_schema_failures(errors, probe_name, schema_name, prefix \\ [])
       when is_list(errors) do
    Enum.map(errors, fn error ->
      schema_failure(
        probe_name,
        schema_name,
        prefix ++ List.wrap(error[:path]),
        error[:message] || "schema validation failed"
      )
    end)
  end

  defp schema_failure(probe_name, schema_name, path, message) do
    %{
      probe: probe_name,
      schema: schema_name,
      path: path,
      message: message
    }
  end
end
