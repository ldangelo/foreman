defmodule ForemanServer.TaskProviders.BeadsAdapter do
  @moduledoc "Production TaskProvider implementation backed by the `br` CLI. Unimplemented callbacks (list_ready, get, claim, complete, fail, reopen, set_priority, add_dependency) return {:error, :not_implemented} until TRD-011..TRD-018 fill them in."

  @behaviour ForemanServer.TaskProvider

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TaskProviders.ProviderError

  @runner Application.compile_env(
            :foreman_server,
            :br_runner,
            ForemanServer.TaskProviders.SystemBrRunner
          )

  @impl true
  def name, do: :beads

  @impl true
  def capabilities do
    %{
      provider_id: :beads,
      contract_version: "br.capabilities.v1",
      supports: [
        :claim,
        :close,
        :reopen,
        :annotate,
        :set_priority,
        :set_assignee,
        :list_dependencies,
        :add_dependency,
        :remove_dependency
      ]
    }
  end

  @impl true
  def available? do
    case System.find_executable("br") do
      nil -> false
      _path -> true
    end
  end

  @doc """
  Invoked by the per-project projector before provider registration. Confirms the
  `br` CLI can locate the project's database. Returns `:ok` on success, or
  `{:error, %ProviderError{}}` on failure (e.g., DATABASE_NOT_FOUND).
  """
  @spec preflight_database(database_path :: String.t(), opts :: keyword()) ::
          :ok | {:error, ProviderError.t()}
  def preflight_database(database_path, opts \\ []) when is_binary(database_path) do
    request = {:where, %{database_path: database_path}}
    project_config = %{database_path: database_path}
    argv = ["where", "--db", database_path, "--json"]
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    TaskProviderTelemetry.emit(
      [:foreman_server, :task_provider, :beads_adapter, :preflight, :start],
      %{system_time: System.system_time()},
      %{argv: argv, timeout_ms: timeout_ms}
    )

    case @runner.cmd(request, project_config, timeout_ms: timeout_ms) do
      {:ok, _response} ->
        TaskProviderTelemetry.emit(
          [:foreman_server, :task_provider, :beads_adapter, :preflight, :ok],
          %{system_time: System.system_time()},
          %{argv: argv}
        )

        :ok

      {:error, %{stdout: stdout, stderr: stderr} = result} ->
        provider_error = build_preflight_error(stdout, stderr, result)

        TaskProviderTelemetry.emit(
          [:foreman_server, :task_provider, :beads_adapter, :preflight, :error],
          %{system_time: System.system_time()},
          %{argv: argv, error: provider_error}
        )

        {:error, provider_error}
    end
  end

  @impl true
  def list_ready(project_config, _opts) when is_map(project_config) do
    database_path =
      case project_config do
        %{database_path: cached_path} when is_binary(cached_path) ->
          cached_path

        %{"database_path" => cached_path} when is_binary(cached_path) ->
          cached_path

        other ->
          raise ArgumentError,
                "expected project_config with binary :database_path, got: #{inspect(other)}"
      end

    case @runner.cmd({:ready, %{database_path: database_path}}, project_config,
           timeout_ms: 30_000
         ) do
      {:ok, %{stdout: stdout}} ->
        parse_list_ready_response(stdout)

      {:error, %{stdout: stdout, stderr: stderr} = result} ->
        {:error, build_list_ready_error(stdout, stderr, result)}
    end
  end

  def list_ready(_opts, project_config) when is_map(project_config) do
    list_ready(project_config, %{})
  end

  defp parse_list_ready_response(stdout) when is_binary(stdout) do
    case String.trim(stdout) do
      "" ->
        {:ok, []}

      json ->
        case Jason.decode(json) do
          {:ok, []} ->
            {:ok, []}

          {:ok, payloads} when is_list(payloads) ->
            payloads
            |> Enum.reduce_while({:ok, []}, fn payload, {:ok, issues} ->
              case parse_issue_payload(payload) do
                {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
                {:error, provider_error} -> {:halt, {:error, provider_error}}
              end
            end)
            |> case do
              {:ok, issues} -> {:ok, Enum.reverse(issues)}
              error -> error
            end

          {:ok, _other} ->
            {:error,
             build_list_ready_contract_error(
               "Beads ready payload must decode to a JSON array of issue objects."
             )}

          {:error, _reason} ->
            {:error, build_list_ready_parse_error()}
        end
    end
  end

  defp parse_list_ready_response(_stdout) do
    {:error, build_list_ready_parse_error()}
  end

  defp parse_issue_payload(%{} = payload) do
    with :ok <- JsonSchemaCache.validate(:ready_issue, payload),
         {:ok, id} <- fetch_required_string(payload, :id),
         {:ok, title} <- fetch_required_string(payload, :title),
         {:ok, priority} <- parse_priority(fetch_payload_value(payload, :priority)),
         {:ok, dependencies} <-
           parse_opaque_string_list(fetch_payload_value(payload, :dependencies), :dependencies),
         {:ok, assignee} <-
           parse_optional_string(fetch_payload_value(payload, :assignee), :assignee),
         {:ok, description} <-
           parse_optional_string(fetch_payload_value(payload, :description), :description),
         {:ok, notes} <- parse_optional_string(fetch_payload_value(payload, :notes), :notes),
         {:ok, design} <- parse_optional_string(fetch_payload_value(payload, :design), :design),
         {:ok, labels} <-
           parse_opaque_string_list(fetch_payload_value(payload, :labels), :labels),
         {:ok, metadata} <- parse_metadata(fetch_payload_value(payload, :metadata)) do
      {:ok,
       %Issue{
         id: id,
         title: title,
         status: "blocked",
         priority: priority,
         dependencies: dependencies,
         assignee: assignee,
         description: description,
         notes: notes,
         design: design,
         labels: labels,
         metadata: metadata
       }}
    else
      {:error, errors} when is_list(errors) ->
        {:error, build_list_ready_schema_validation_error(errors)}

      {:error, provider_error} ->
        {:error, provider_error}
    end
  end

  defp parse_issue_payload(_payload) do
    {:error, build_list_ready_contract_error("Beads ready issue payload must be a JSON object.")}
  end

  defp fetch_payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key, Map.get(payload, to_string(key)))
  end

  defp fetch_required_string(payload, key) do
    case fetch_payload_value(payload, key) do
      value when is_binary(value) ->
        {:ok, value}

      _other ->
        {:error,
         build_list_ready_contract_error(
           "Beads ready issue field #{inspect(key)} must be a string."
         )}
    end
  end

  defp parse_optional_string(nil, _field), do: {:ok, nil}

  defp parse_optional_string(value, _field) when is_binary(value), do: {:ok, value}

  defp parse_optional_string(_value, field) do
    {:error,
     build_list_ready_contract_error(
       "Beads ready issue field #{inspect(field)} must be a string or null."
     )}
  end

  defp parse_priority(nil), do: {:ok, 0}

  defp parse_priority(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_priority(_value) do
    {:error,
     build_list_ready_contract_error(
       "Beads ready issue field :priority must be a non-negative integer."
     )}
  end

  defp parse_opaque_string_list(nil, _field), do: {:ok, []}

  defp parse_opaque_string_list(values, field) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error,
       build_list_ready_contract_error(
         "Beads ready issue field #{inspect(field)} must be a list of strings."
       )}
    end
  end

  defp parse_opaque_string_list(_values, field) do
    {:error,
     build_list_ready_contract_error(
       "Beads ready issue field #{inspect(field)} must be a list of strings."
     )}
  end

  defp parse_metadata(nil), do: {:ok, %{}}
  defp parse_metadata(%{} = metadata), do: {:ok, metadata}

  defp parse_metadata(_metadata) do
    {:error,
     build_list_ready_contract_error("Beads ready issue field :metadata must be an object.")}
  end

  defp build_list_ready_error(stdout, stderr, result) do
    stderr_byte_count = byte_size(stderr)
    command = "br ready"

    case parse_br_error_envelope(stderr, stdout) do
      {:ok, envelope} ->
        envelope
        |> ProviderErrorInput.from_br_envelope()
        |> CodeMap.build_provider_error(command, stderr_byte_count)

      :error ->
        CodeMap.build_provider_error(
          ProviderErrorInput.from_local(
            "BR_PARSE_ERROR",
            "Beads CLI returned an unreadable error envelope.",
            "Verify the installed br version and retry.",
            false
          ),
          command,
          stderr_byte_count
        )
    end
    |> maybe_put_exit_code(result)
  end

  defp build_list_ready_schema_validation_error(errors) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "SCHEMA_VALIDATION_FAILED",
        "Beads ready issue payload failed schema validation.",
        "Refresh the cached schema or re-fetch the Beads payload.",
        false,
        missing_fields_from(errors)
      ),
      "br ready",
      0
    )
  end

  defp build_list_ready_contract_error(message) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_CONTRACT_MISMATCH",
        message,
        "Update the adapter or install a supported Beads CLI version.",
        false
      ),
      "br ready",
      0
    )
  end

  defp build_list_ready_parse_error do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_PARSE_ERROR",
        "Beads ready payload could not be parsed.",
        "Check the Beads output format or refresh the CLI contract cache.",
        false
      ),
      "br ready",
      0
    )
  end

  defp missing_fields_from(errors) when is_list(errors) do
    errors
    |> Enum.flat_map(fn
      %{path: [field | _rest], message: "is required"} -> [to_string(field)]
      _other -> []
    end)
    |> Enum.uniq()
  end

  @impl true
  def get(_id, _opts), do: {:error, :not_implemented}

  @impl true
  def claim(_id, _actor, _opts), do: {:error, :not_implemented}

  @impl true
  def complete(_id, _actor, _opts), do: {:error, :not_implemented}

  @impl true
  def fail(_id, _actor, _opts), do: {:error, :not_implemented}

  @impl true
  def reopen(_id, _actor, _opts), do: {:error, :not_implemented}

  @impl true
  def set_priority(id, priority, project_config) do
    if priority in 0..4 do
      cached_path =
        case project_config do
          %{database_path: database_path} when is_binary(database_path) ->
            database_path

          %{"database_path" => database_path} when is_binary(database_path) ->
            database_path

          other ->
            raise ArgumentError,
                  "expected project_config with binary :database_path, got: #{inspect(other)}"
        end

      case @runner.cmd(
             {:set_priority, %{id: id, priority: priority, database_path: cached_path}},
             %{},
             timeout_ms: 30_000
           ) do
        {:ok, _response} ->
          :ok

        {:error, %{stdout: stdout, stderr: stderr} = result} ->
          stderr_byte_count = byte_size(stderr)
          command = "br update"

          provider_error =
            case parse_br_error_envelope(stderr, stdout) do
              {:ok, envelope} ->
                envelope
                |> ProviderErrorInput.from_br_envelope()
                |> CodeMap.build_provider_error(command, stderr_byte_count)

              :error ->
                CodeMap.build_provider_error(
                  ProviderErrorInput.from_local(
                    "BR_PARSE_ERROR",
                    "Beads CLI returned an unreadable error envelope.",
                    "Verify the installed br version and retry.",
                    false
                  ),
                  command,
                  stderr_byte_count
                )
            end
            |> maybe_put_exit_code(result)

          {:error, provider_error}
      end
    else
      {:error,
       CodeMap.build_provider_error(
         ProviderErrorInput.from_local(
           "INVALID_PRIORITY",
           "Issue priority must be between 0 and 4.",
           "Pass a Beads priority level in the inclusive range 0..4.",
           false
         ),
         nil,
         0
       )}
    end
  end

  @impl true
  def add_dependency(_id, _depends_on_id, _opts), do: {:error, :not_implemented}

  @doc false
  def __runner__, do: @runner

  @doc false
  def __code_map__, do: CodeMap

  @doc false
  def behaviour_info(:callbacks), do: ForemanServer.TaskProvider.behaviour_info(:callbacks)

  def behaviour_info(:optional_callbacks), do: []

  defp build_preflight_error(stdout, stderr, result) do
    stderr_byte_count = byte_size(stderr)
    command = "br where"

    case parse_br_error_envelope(stderr, stdout) do
      {:ok, envelope} ->
        envelope
        |> ProviderErrorInput.from_br_envelope()
        |> CodeMap.build_provider_error(command, stderr_byte_count)

      :error ->
        CodeMap.build_provider_error(
          ProviderErrorInput.from_local(
            "BR_PARSE_ERROR",
            "Beads CLI returned an unreadable error envelope.",
            "Verify the installed br version and retry.",
            false
          ),
          command,
          stderr_byte_count
        )
    end
    |> maybe_put_exit_code(result)
  end

  defp parse_br_error_envelope(primary, secondary) do
    case decode_json_map(primary) do
      {:ok, envelope} -> {:ok, envelope}
      :error -> decode_json_map(secondary)
    end
  end

  defp decode_json_map(payload) when is_binary(payload) and payload != "" do
    case Jason.decode(payload) do
      {:ok, %{} = envelope} -> {:ok, envelope}
      _ -> :error
    end
  end

  defp decode_json_map(_payload), do: :error

  defp maybe_put_exit_code(provider_error, %{exit_code: exit_code})
       when is_integer(exit_code) and is_map(provider_error) do
    Map.put(
      provider_error,
      :context,
      Map.put(Map.fetch!(provider_error, :context), :exit_code, exit_code)
    )
  end

  defp maybe_put_exit_code(provider_error, _result), do: provider_error
end
