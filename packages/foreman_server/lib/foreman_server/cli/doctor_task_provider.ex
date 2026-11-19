defmodule ForemanServer.CLI.DoctorTaskProvider do
  @moduledoc false

  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TaskProviders.BeadsOrphanJanitorSupervisor
  alias ForemanServer.TaskProviders.BeadsOrphanJanitor

  @runner Application.compile_env(
            :foreman_server,
            :br_runner,
            ForemanServer.TaskProviders.SystemBrRunner
          )
  @schema_cache_name :foreman_server_json_schema_cache
  @doctor_probe_event [:foreman_server, :task_provider, :beads_adapter, :doctor, :probe]
  @probe_timeout_ms 30_000
  @version_argv ["br", "--version"]

  @kata_runner_default ForemanServer.TaskProviders.SystemKataRunner
  @kata_version_argv ["--version"]
  @kata_sample_list_argv ["list", "--limit", "1", "--json"]

  @type run_result :: :ok | {:error, pos_integer(), String.t()}

  @spec run([String.t()]) :: run_result()
  def run([]) do
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
      build_resolved_report(
        capabilities,
        provider_module,
        project_id,
        project_config,
        database_path
      )
    else
      {:error, reason} ->
        janitor_enabled =
          Application.get_env(:foreman_server, :start_beads_orphan_janitor?, false)

        {janitor_running, orphan_backlog} = orphan_backlog_snapshot(project_id, janitor_enabled)

        %{
          project_id: project_id,
          healthy: false,
          provider_id: normalize_provider_id(provider_ref),
          contract_version: nil,
          br_version: nil,
          capabilities: nil,
          sample_ready: nil,
          schema_validation_failures: [],
          janitor_enabled: janitor_enabled,
          janitor_running: janitor_running,
          orphan_backlog: orphan_backlog,
          error: %{
            code: task_provider_error_code(reason),
            message: "task_provider could not be resolved",
            hint: inspect(reason),
            exit_code: nil,
            stderr_byte_count: 0,
            redacted_fields: []
          }
        }
    end
  end

  # The probe follows the provider's declared storage. A CLI-process provider (Kata) has
  # no database file, so it is never held to the Beads `database_path` check.
  defp build_resolved_report(
         %{storage_scheme: :cli_process, provider_id: :kata} = capabilities,
         provider_module,
         project_id,
         project_config,
         _database_path
       ) do
    build_kata_report(capabilities, provider_module, project_id, project_config)
  end

  defp build_resolved_report(
         capabilities,
         provider_module,
         project_id,
         project_config,
         database_path
       ) do
    # Only the Beads probe validates against the br JSON schemas; a Kata run never starts them.
    :ok = ensure_schema_cache_started()

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

    janitor_enabled = Application.get_env(:foreman_server, :start_beads_orphan_janitor?, false)
    {janitor_running, orphan_backlog} = orphan_backlog_snapshot(project_id, janitor_enabled)

    report =
      Map.merge(report, %{
        janitor_enabled: janitor_enabled,
        janitor_running: janitor_running,
        orphan_backlog: orphan_backlog
      })

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
  end

  defp build_kata_report(capabilities, provider_module, project_id, project_config) do
    report = %{
      project_id: project_id,
      healthy: true,
      provider_id: normalize_provider_id(capabilities[:provider_id]),
      contract_version: capabilities[:contract_version],
      kata_version: nil,
      warnings: [],
      sample_list: nil,
      schema_validation_failures: []
    }

    cwd = fetch_value(project_config, :cwd)

    cond do
      not is_binary(cwd) or cwd == "" ->
        put_unhealthy(report, diagnostic("CWD_MISSING", "task_provider.config.cwd is missing"))

      not provider_module.available?() ->
        put_unhealthy(report, kata_unavailable_error())

      true ->
        probe_kata_project(report, cwd)
    end
  end

  # `available?/0` only says that kata cannot be used. Name the cause: no binary on PATH, or
  # `kata --version` failing (whose exit code and stderr byte count are reported; stderr text
  # is never read).
  defp kata_unavailable_error do
    case System.find_executable("kata") do
      nil ->
        diagnostic("PROVIDER_MISSING", "kata not installed")

      _path ->
        case kata_version_probe() do
          {:error, error} ->
            %{error | code: "PROVIDER_MISSING", message: "kata --version failed"}

          {:ok, _banner} ->
            diagnostic("PROVIDER_MISSING", "kata --version failed")
        end
    end
  end

  defp probe_kata_project(report, cwd) do
    case kata_version_probe() do
      {:ok, banner} ->
        report
        |> Map.put(:kata_version, %{exit_code: 0, stdout: banner})
        |> Map.put(:warnings, kata_version_warnings(banner))
        |> sample_kata_listing(cwd)

      {:error, error} ->
        put_unhealthy(report, error)
    end
  end

  defp kata_version_probe do
    case kata_runner().cmd(@kata_version_argv, File.cwd!(), timeout_ms: @probe_timeout_ms) do
      {:ok, stdout} when is_binary(stdout) -> {:ok, String.trim(stdout)}
      {:error, %ProviderError{} = error} -> {:error, provider_error_map(error)}
    end
  end

  # Resolved at call time, like KataAdapter, so both follow a runtime rebinding of `:kata_runner`.
  defp kata_runner, do: Application.get_env(:foreman_server, :kata_runner, @kata_runner_default)

  defp sample_kata_listing(report, cwd) do
    case kata_runner().cmd(@kata_sample_list_argv, cwd, timeout_ms: @probe_timeout_ms) do
      {:ok, stdout} when is_binary(stdout) ->
        case decode_kata_listing(stdout) do
          {:ok, issue_count} ->
            Map.put(report, :sample_list, %{outcome: "ok", issue_count: issue_count})

          {:error, failures} ->
            report
            |> Map.put(:healthy, false)
            |> Map.put(:schema_validation_failures, failures)
        end

      {:error, %ProviderError{} = error} ->
        put_unhealthy(report, provider_error_map(error))
    end
  end

  # `kata list --json` prints an envelope whose `issues` is the array of issue records.
  defp decode_kata_listing(stdout) do
    case decode_json(stdout, "list_envelope", "list") do
      {:ok, %{"issues" => issues}} when is_list(issues) ->
        {:ok, length(issues)}

      {:ok, %{"issues" => _other}} ->
        {:error, [schema_failure("list", "list_envelope", ["issues"], "issues must be an array")]}

      {:ok, %{}} ->
        {:error, [schema_failure("list", "list_envelope", ["issues"], "issues is missing")]}

      {:ok, _not_an_object} ->
        {:error,
         [schema_failure("list", "list_envelope", [], "sample list must decode to a JSON object")]}

      {:error, failures} ->
        {:error, failures}
    end
  end

  # Warnings never change `healthy`: a version outside `accepted_kata_versions`, or one that
  # is not a semantic version, only warns.
  defp kata_version_warnings(banner) do
    case parse_kata_version(banner) do
      {:ok, %Version{} = version} ->
        accepted_kata_version_warnings(version)

      {:unparseable, raw} ->
        [
          warning(
            "KATA_VERSION_UNPARSEABLE",
            "kata version #{inspect(raw)} is not a semantic version"
          )
        ]
    end
  end

  # The banner's first line is `kata v<semver>`; the leading `v` is not part of the version.
  defp parse_kata_version(banner) do
    [first_line | _rest] = String.split(banner, "\n", parts: 2)

    case Regex.run(~r/\Akata\s+v?(\S+)/, first_line) do
      [_match, identifier] ->
        case Version.parse(identifier) do
          {:ok, version} -> {:ok, version}
          :error -> {:unparseable, identifier}
        end

      nil ->
        {:unparseable, first_line}
    end
  end

  # `accepted_kata_versions` is a list of `Version.match?/2` requirement strings; a version is
  # accepted when it satisfies at least one. Absent or empty means no range is configured.
  defp accepted_kata_version_warnings(version) do
    :foreman_server
    |> Application.get_env(:task_provider, [])
    |> Keyword.get(:accepted_kata_versions)
    |> case do
      nil -> []
      [] -> []
      requirements when is_list(requirements) -> range_warnings(version, requirements)
      other -> [invalid_requirement_warning(other)]
    end
  end

  defp range_warnings(version, requirements) do
    parsed = Enum.map(requirements, &parse_requirement/1)
    invalid = for {:invalid, entry} <- parsed, do: invalid_requirement_warning(entry)
    valid = for {:ok, entry, requirement} <- parsed, do: {entry, requirement}

    accepted? =
      Enum.any?(valid, fn {_entry, requirement} -> Version.match?(version, requirement) end)

    if valid == [] or accepted? do
      invalid
    else
      accepted_entries = Enum.map(valid, fn {entry, _requirement} -> entry end)

      invalid ++
        [
          warning(
            "KATA_VERSION_OUT_OF_RANGE",
            "kata #{version} is outside accepted_kata_versions #{inspect(accepted_entries)}"
          )
        ]
    end
  end

  defp parse_requirement(entry) when is_binary(entry) do
    case Version.parse_requirement(entry) do
      {:ok, requirement} -> {:ok, entry, requirement}
      :error -> {:invalid, entry}
    end
  end

  defp parse_requirement(entry), do: {:invalid, entry}

  defp invalid_requirement_warning(entry) do
    warning(
      "KATA_VERSION_REQUIREMENT_INVALID",
      "accepted_kata_versions entry #{inspect(entry)} is not a valid version requirement"
    )
  end

  defp warning(code, message), do: %{code: code, message: message}

  defp diagnostic(code, message) do
    %{
      code: code,
      message: message,
      hint: nil,
      exit_code: nil,
      stderr_byte_count: 0,
      redacted_fields: []
    }
  end

  defp task_provider_error_code({:invalid_task_provider_reference, _}),
    do: "TASK_PROVIDER_REFERENCE_INVALID"

  defp task_provider_error_code(_reason), do: "TASK_PROVIDER_NOT_CONFIGURED"

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

  # CQRS read path: NEVER call BeadsOrphanJanitor.run_scan/2 from here.
  # The janitor maintains its own scan loop and caches the most recent
  # counters in state.last_counters; we read that snapshot via the
  # supervisor. Calling run_scan/2 here would invoke
  # BeadsAdapter.complete/3 and mutate provider state from a read path.
  defp orphan_backlog_snapshot(project_id, janitor_enabled) do
    if janitor_enabled do
      case BeadsOrphanJanitorSupervisor.snapshot(project_id) do
        {:ok, %BeadsOrphanJanitor.Counters{} = counters} ->
          {true, counters_to_map(counters)}

        {:ok, nil} ->
          {true, nil}

        {:error, :not_running} ->
          {false, nil}
      end
    else
      {false, nil}
    end
  end

  defp counters_to_map(counters) do
    %{
      lines_processed: counters.lines_processed,
      lines_tagged: counters.lines_tagged,
      lines_untagged: counters.lines_untagged,
      lines_malformed: counters.lines_malformed,
      lines_retained: counters.lines_retained,
      lines_closed: counters.lines_closed,
      lines_age_young: counters.lines_age_young,
      lines_no_linked_at: counters.lines_no_linked_at
    }
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
    case try_full_module(provider_module) do
      {:ok, _} = ok ->
        ok

      :not_full_module ->
        # Short name like "beads" — look up the loaded module via the routing
        # snapshot. The snapshot shape is mixed: atom-keyed provider entries
        # (`%{beads => BeadsAdapter, ...}`) merged with string-keyed active
        # project entries (`%{"project-1" => BeadsAdapter, ...}`). We only
        # match against atom keys — a project ID must never be resolved as a
        # provider module. Atom.to_string/1 is only called on existing atoms,
        # so the input string is never interned.
        match =
          Enum.find_value(TaskProviderRegistry.routing_snapshot(), fn
            {id, module} when is_atom(id) ->
              if Atom.to_string(id) == provider_module, do: module

            _ ->
              nil
          end)

        if is_atom(match) and not is_nil(match) do
          {:ok, match}
        else
          {:error, :task_provider_not_configured}
        end
    end
  end

  defp resolve_provider_module(provider_module),
    do: {:error, {:invalid_task_provider_reference, provider_module}}

  # Validate a full module name without interning arbitrary input.
  # Module.safe_concat/1 raises ArgumentError on invalid aliases (lowercase,
  # spaces, reserved words, etc.) BEFORE creating the atom, so a malformed
  # config string can never grow the atom table.
  defp try_full_module(provider_module) when is_binary(provider_module) do
    try do
      candidate = Module.safe_concat([provider_module])

      if Code.ensure_loaded?(candidate) and function_exported?(candidate, :capabilities, 0) do
        {:ok, candidate}
      else
        :not_full_module
      end
    rescue
      ArgumentError -> :not_full_module
    end
  end

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
