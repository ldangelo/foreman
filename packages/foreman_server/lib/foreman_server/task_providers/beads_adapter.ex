defmodule ForemanServer.TaskProviders.BeadsAdapter do
  @moduledoc "Production TaskProvider implementation backed by the `br` CLI. Unimplemented callbacks (list_ready, get, claim, complete, fail, reopen, set_priority, add_dependency) return {:error, :not_implemented} until TRD-011..TRD-018 fill them in."

  @behaviour ForemanServer.TaskProvider

  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry
  alias ForemanServer.TaskProviders.JsonSchemaCache
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.Aggregates.BeadsDbLease
  require Logger

  @runner Application.compile_env(
            :foreman_server,
            :br_runner,
            ForemanServer.TaskProviders.SystemBrRunner
          )
  @id_format_source "^[A-Za-z0-9][A-Za-z0-9:_-]*$"
  @id_format_regex Regex.compile!(@id_format_source)

  @valid_task_types [:task, :bug, :feature, :epic, :chore, :docs, :question]

  @coordination_status_schema_version "br.coordination.v1"

  @impl true
  def name, do: :beads

  @doc """
  Advertises the upstream `:br` capability contract for the BeadsAdapter provider.

  `supports` lists every operation the adapter implements, including the new
  `:create` operation that delegates to `br create` and links the new bead
  back to the dispatching Foreman task via the `--agent-context` JSON envelope
  (REQ-020 / REQ-021). The remaining nine entries cover the existing
  lifecycle, priority, dependency, and assignment operations.
  """
  @impl true
  def capabilities do
    %{
      provider_id: :beads,
      contract_version: "br.capabilities.v1",
      id_format: @id_format_source,
      supports: [
        :claim,
        :close,
        :reopen,
        :annotate,
        :set_priority,
        :set_assignee,
        :list_dependencies,
        :add_dependency,
        :remove_dependency,
        :create
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

  @valid_task_types ~w(task bug feature epic chore docs question)

  @doc """
  Creates a new bead in the upstream `br` database linked back to the
  dispatching Foreman task via the `--agent-context` JSON envelope.

  Implements the `ForemanServer.TaskProvider.create/2` callback (TRD-003).
  Pre-emptively validates the canonical seven-key `attrs` map (Architecture
  Decision #12) before constructing argv: rejects missing/empty `title`,
  out-of-range `priority` (must be 0..4), `task_type` outside the closed
  enum, and missing correlation handles (`task_id`/`command_id`) — all
  routed through the appropriate `BeadsAdapter.CodeMap` row before any
  `BrRunner.cmd/3` call.

  Resolves `database_path` from `TaskProvider.Registry.project_config/1`
  (added in TRD-005-TASK). On registry miss, returns `CREATE_FAILED` as a
  terminal config error (no retry).

  Validates PRD ACs: AC-020-1, AC-021-1, AC-021-3, AC-026-2, AC-026-3.
  """
  @impl true
  def create(project_id, attrs)
      when is_binary(project_id) and project_id != "" and is_map(attrs) do
    with :ok <- validate_create_attrs(attrs),
         {:ok, project_config} <- resolve_project_config(project_id),
         {:ok, database_path} <- fetch_database_path(project_config),
         payload = build_create_payload(attrs),
         :ok <- emit_create_start(project_id, attrs),
         synthetic_run_id = "create:#{project_id}:#{System.system_time(:nanosecond)}",
         {:ok, issue} <-
           BeadsDbLease.with_lease(database_path, synthetic_run_id, synthetic_run_id, fn ->
             run_create(project_id, project_config, payload)
           end) do
      emit_create_ok(project_id, attrs, issue)
      {:ok, issue}
    else
      :error ->
        {:error,
         CodeMap.build_provider_error(
           ProviderErrorInput.from_local(
             "CREATE_FAILED",
             "Could not resolve database_path for project #{project_id}.",
             "Ensure the project is registered with a beads database_path.",
             false
           ),
           nil,
           0
         )}

      {:error, provider_error} = error ->
        emit_create_error(project_id, attrs, provider_error)
        error
    end
  end

  def create(project_id, _attrs) when is_binary(project_id) do
    {:error,
     CodeMap.build_provider_error(
       ProviderErrorInput.from_local(
         "INVALID_TITLE",
         "create/2 requires a project_id and an attrs map.",
         "Pass a non-empty project_id and a canonical attrs map (see Architecture Decision #12).",
         false
       ),
       nil,
       0
     )}
  end

  def create(_project_id, _attrs) do
    {:error,
     CodeMap.build_provider_error(
       ProviderErrorInput.from_local(
         "INVALID_TITLE",
         "create/2 requires a project_id and an attrs map.",
         "Pass a non-empty project_id and a canonical attrs map (see Architecture Decision #12).",
         false
       ),
       nil,
       0
     )}
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

  @spec coordination_status(map(), keyword()) :: {:ok, [Issue.t()]} | {:error, ProviderError.t()}
  def coordination_status(project_config, opts \\ [])
      when is_map(project_config) and is_list(opts) do
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

    argv = ["coordination", "status", "--db", database_path, "--json"]

    case @runner.cmd({:coordination_status, %{}}, %{database_path: database_path},
           timeout_ms: Keyword.get(opts, :timeout_ms, 30_000)
         ) do
      {:ok, %{stdout: stdout}} ->
        parse_coordination_status_response(stdout, argv)

      {:error, %{stdout: stdout, stderr: stderr} = result} ->
        {:error, build_coordination_status_error(stdout, stderr, result, argv)}
    end
  end

  defp parse_coordination_status_response(stdout, argv) when is_binary(stdout) do
    case String.trim(stdout) do
      "" ->
        {:ok, []}

      json ->
        case Jason.decode(json) do
          {:ok, []} ->
            {:ok, []}

          {:ok, payloads} when is_list(payloads) ->
            parse_coordination_issue_list(payloads, argv)

          {:ok, %{} = payload} ->
            parse_coordination_issue_container(payload, argv)

          {:ok, _other} ->
            {:error,
             build_coordination_status_contract_error(
               "Beads coordination status payload must decode to a JSON object or array.",
               argv
             )}

          {:error, _reason} ->
            {:error, build_coordination_status_parse_error(argv)}
        end
    end
  end

  defp parse_coordination_status_response(_stdout, argv) do
    {:error, build_coordination_status_parse_error(argv)}
  end

  defp parse_coordination_issue_container(payload, argv) when is_map(payload) do
    case fetch_payload_value(payload, :schema_version) do
      nil ->
        parse_coordination_legacy_container(payload, argv)

      @coordination_status_schema_version ->
        parse_coordination_claims_envelope(payload, argv)

      other ->
        {:error,
         build_coordination_status_contract_error(
           "Beads coordination status schema_version #{inspect(other)} is unsupported; expected #{inspect(@coordination_status_schema_version)}.",
           argv
         )}
    end
  end

  defp parse_coordination_legacy_container(payload, argv) when is_map(payload) do
    case fetch_payload_value(payload, :issues) do
      issues when is_list(issues) ->
        parse_coordination_issue_list(issues, argv)

      nil ->
        case parse_coordination_issue_payload(payload, argv) do
          {:ok, issue} -> {:ok, [issue]}
          {:error, provider_error} -> {:error, provider_error}
        end

      _other ->
        {:error,
         build_coordination_status_contract_error(
           "Beads coordination status field :issues must be a JSON array.",
           argv
         )}
    end
  end

  defp parse_coordination_claims_envelope(payload, argv) when is_map(payload) do
    case fetch_payload_value(payload, :claims) do
      claims when is_list(claims) ->
        parse_coordination_claim_list(claims, argv)

      nil ->
        {:error,
         build_coordination_status_contract_error(
           "Beads coordination status #{@coordination_status_schema_version} payload is missing the :claims array.",
           argv
         )}

      _other ->
        {:error,
         build_coordination_status_contract_error(
           "Beads coordination status field :claims must be a JSON array.",
           argv
         )}
    end
  end

  defp parse_coordination_claim_list(claims, argv) when is_list(claims) do
    claims
    |> Enum.reduce_while({:ok, []}, fn claim, {:ok, issues} ->
      case parse_coordination_claim(claim, argv) do
        {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
        {:error, provider_error} -> {:halt, {:error, provider_error}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp parse_coordination_claim(claim, argv) when is_map(claim) do
    case fetch_payload_value(claim, :issue) do
      issue_payload when is_map(issue_payload) ->
        with {:ok, issue} <- parse_coordination_issue_payload(issue_payload, argv),
             {:ok, counts} <- parse_coordination_claim_counts(issue_payload, argv) do
          {:ok, %Issue{issue | metadata: Map.merge(issue.metadata, counts)}}
        end

      nil ->
        {:error,
         build_coordination_status_contract_error(
           "Beads coordination status claim entries must include an :issue object.",
           argv
         )}

      _other ->
        {:error,
         build_coordination_status_contract_error(
           "Beads coordination status claim field :issue must be a JSON object.",
           argv
         )}
    end
  end

  defp parse_coordination_claim(_claim, argv) do
    {:error,
     build_coordination_status_contract_error(
       "Beads coordination status claim entries must be JSON objects.",
       argv
     )}
  end

  # `br.coordination.v1` reports dependency/dependent cardinality only and never
  # the linked ids, so the counts are preserved under `metadata` instead of being
  # silently flattened into the empty `dependencies`/`dependents` lists.
  defp parse_coordination_claim_counts(issue_payload, argv) when is_map(issue_payload) do
    Enum.reduce_while([:dependency_count, :dependent_count], {:ok, %{}}, fn key, {:ok, counts} ->
      case fetch_payload_value(issue_payload, key) do
        nil ->
          {:cont, {:ok, counts}}

        value when is_integer(value) and value >= 0 ->
          {:cont, {:ok, Map.put(counts, to_string(key), value)}}

        _other ->
          {:halt,
           {:error,
            build_coordination_status_contract_error(
              "Beads coordination status field #{inspect(key)} must be a non-negative integer.",
              argv
            )}}
      end
    end)
  end

  defp parse_coordination_issue_list(payloads, argv) when is_list(payloads) do
    payloads
    |> Enum.reduce_while({:ok, []}, fn payload, {:ok, issues} ->
      case parse_coordination_issue_payload(payload, argv) do
        {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
        {:error, provider_error} -> {:halt, {:error, provider_error}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp parse_coordination_issue_payload(payload, argv) when is_map(payload) do
    with {:ok, id} <- fetch_coordination_required_string(payload, :id, argv),
         {:ok, title} <- fetch_coordination_optional_string(payload, :title, id, argv),
         {:ok, status} <- fetch_coordination_required_string(payload, :status, argv),
         {:ok, priority} <-
           parse_coordination_priority(fetch_payload_value(payload, :priority), argv),
         {:ok, dependencies} <-
           parse_coordination_dependencies(fetch_payload_value(payload, :dependencies), argv),
         {:ok, dependents} <-
           parse_coordination_dependents(fetch_payload_value(payload, :dependents), argv),
         {:ok, assignee} <-
           fetch_coordination_optional_string(payload, :assignee, nil, argv),
         {:ok, description} <-
           fetch_coordination_optional_string(payload, :description, nil, argv),
         {:ok, notes} <- fetch_coordination_optional_string(payload, :notes, nil, argv),
         {:ok, design} <- fetch_coordination_optional_string(payload, :design, nil, argv),
         {:ok, labels} <-
           parse_coordination_string_list(fetch_payload_value(payload, :labels), :labels, argv),
         {:ok, metadata} <-
           parse_coordination_metadata(fetch_payload_value(payload, :metadata), argv) do
      {:ok,
       %Issue{
         id: id,
         title: title,
         status: status,
         priority: priority,
         dependencies: dependencies,
         dependents: dependents,
         assignee: assignee,
         description: description,
         notes: notes,
         design: design,
         labels: labels,
         metadata: metadata
       }}
    end
  end

  defp parse_coordination_issue_payload(_payload, argv) do
    {:error,
     build_coordination_status_contract_error(
       "Beads coordination status issue payload must be a JSON object.",
       argv
     )}
  end

  defp fetch_coordination_required_string(payload, key, argv) do
    case fetch_payload_value(payload, key) do
      value when is_binary(value) ->
        {:ok, value}

      _other ->
        {:error,
         build_coordination_status_contract_error(
           "Beads coordination status field #{inspect(key)} must be a string.",
           argv
         )}
    end
  end

  defp fetch_coordination_optional_string(payload, key, default, argv) do
    case fetch_payload_value(payload, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        {:ok, value}

      _other ->
        {:error,
         build_coordination_status_contract_error(
           "Beads coordination status field #{inspect(key)} must be a string or null.",
           argv
         )}
    end
  end

  defp parse_coordination_priority(nil, _argv), do: {:ok, 0}

  defp parse_coordination_priority(value, _argv) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp parse_coordination_priority(_value, argv) do
    {:error,
     build_coordination_status_contract_error(
       "Beads coordination status field :priority must be a non-negative integer.",
       argv
     )}
  end

  defp parse_coordination_dependencies(nil, _argv), do: {:ok, []}

  defp parse_coordination_dependencies(values, argv) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, dependencies} ->
      case parse_coordination_dependency(value, argv) do
        {:ok, dependency} -> {:cont, {:ok, [dependency | dependencies]}}
        {:error, provider_error} -> {:halt, {:error, provider_error}}
      end
    end)
    |> case do
      {:ok, dependencies} -> {:ok, Enum.reverse(dependencies)}
      error -> error
    end
  end

  defp parse_coordination_dependencies(_values, argv) do
    {:error,
     build_coordination_status_contract_error(
       "Beads coordination status field :dependencies must be a list of strings or issue objects.",
       argv
     )}
  end

  defp parse_coordination_dependency(value, _argv) when is_binary(value), do: {:ok, value}

  defp parse_coordination_dependency(%{} = payload, argv) do
    parse_coordination_issue_payload(payload, argv)
  end

  defp parse_coordination_dependency(_value, argv) do
    {:error,
     build_coordination_status_contract_error(
       "Beads coordination status dependency entries must be strings or issue objects.",
       argv
     )}
  end

  defp parse_coordination_dependents(nil, _argv), do: {:ok, []}

  defp parse_coordination_dependents(values, argv) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, dependents} ->
      case value do
        %{} = payload ->
          case parse_coordination_issue_payload(payload, argv) do
            {:ok, dependent} -> {:cont, {:ok, [dependent | dependents]}}
            {:error, provider_error} -> {:halt, {:error, provider_error}}
          end

        _other ->
          {:halt,
           {:error,
            build_coordination_status_contract_error(
              "Beads coordination status dependent entries must be issue objects.",
              argv
            )}}
      end
    end)
    |> case do
      {:ok, dependents} -> {:ok, Enum.reverse(dependents)}
      error -> error
    end
  end

  defp parse_coordination_dependents(_values, argv) do
    {:error,
     build_coordination_status_contract_error(
       "Beads coordination status field :dependents must be a list of issue objects.",
       argv
     )}
  end

  defp parse_coordination_string_list(nil, _field, _argv), do: {:ok, []}

  defp parse_coordination_string_list(values, field, argv) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error,
       build_coordination_status_contract_error(
         "Beads coordination status field #{inspect(field)} must be a list of strings.",
         argv
       )}
    end
  end

  defp parse_coordination_string_list(_values, field, argv) do
    {:error,
     build_coordination_status_contract_error(
       "Beads coordination status field #{inspect(field)} must be a list of strings.",
       argv
     )}
  end

  defp parse_coordination_metadata(nil, _argv), do: {:ok, %{}}
  defp parse_coordination_metadata(%{} = metadata, _argv), do: {:ok, metadata}

  defp parse_coordination_metadata(_metadata, argv) do
    {:error,
     build_coordination_status_contract_error(
       "Beads coordination status field :metadata must be an object.",
       argv
     )}
  end

  defp build_coordination_status_error(stdout, stderr, result, argv) do
    stderr_byte_count = byte_size(stderr)
    command = scrubbed_coordination_status_command(argv)

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

  defp build_coordination_status_contract_error(message, argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_CONTRACT_MISMATCH",
        message,
        "Update the adapter or install a supported Beads CLI version.",
        false
      ),
      scrubbed_coordination_status_command(argv),
      0
    )
  end

  defp build_coordination_status_parse_error(argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_PARSE_ERROR",
        "Beads coordination status payload could not be parsed.",
        "Check the Beads output format or refresh the CLI contract cache.",
        false
      ),
      scrubbed_coordination_status_command(argv),
      0
    )
  end

  defp scrubbed_coordination_status_command(argv) do
    argv
    |> TaskProviderTelemetry.scrub_argv()
    |> then(&["br" | &1])
    |> Enum.join(" ")
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
         dependents: [],
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

  defp parse_closed_issue_response(stdout, task_id) when is_binary(stdout) do
    case String.trim(stdout) do
      "" ->
        {:error, build_complete_parse_error()}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = payload} ->
            parse_closed_issue_payload(payload, task_id)

          {:ok, [%{} = payload]} ->
            parse_closed_issue_payload(payload, task_id)

          {:ok, _other} ->
            {:error,
             build_complete_contract_error(
               "Beads closed issue payload must decode to a JSON object."
             )}

          {:error, _reason} ->
            {:error, build_complete_parse_error()}
        end
    end
  end

  defp parse_closed_issue_response(_stdout, _task_id) do
    {:error, build_complete_parse_error()}
  end

  defp parse_closed_issue_payload(%{} = payload, task_id) do
    with :ok <- JsonSchemaCache.validate(:closed_issue, payload),
         {:ok, id} <- fetch_required_string(payload, :id),
         :ok <- assert_close_id_matches(id, task_id),
         :ok <- assert_close_status(payload),
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
         status: "closed",
         priority: priority,
         dependencies: dependencies,
         dependents: [],
         assignee: assignee,
         description: description,
         notes: notes,
         design: design,
         labels: labels,
         metadata: metadata
       }}
    else
      {:error, errors} when is_list(errors) ->
        {:error, build_complete_schema_validation_error(errors)}

      {:error, provider_error} ->
        {:error, provider_error}
    end
  end

  defp assert_close_id_matches(id, id), do: :ok

  defp assert_close_id_matches(_id, _expected) do
    {:error,
     build_complete_contract_error("Beads close ack id does not match the requested task.")}
  end

  defp assert_close_status(%{"status" => "closed"}), do: :ok
  defp assert_close_status(%{status: "closed"}), do: :ok

  defp assert_close_status(_payload) do
    {:error, build_complete_contract_error("Beads close ack did not return status: closed.")}
  end

  defp build_complete_error(stdout, stderr, result, task_id) do
    stderr_byte_count = byte_size(stderr)
    command = "br close"

    case parse_br_error_envelope(stderr, stdout) do
      {:ok, envelope} ->
        provider_error =
          envelope
          |> ProviderErrorInput.from_br_envelope()
          |> CodeMap.build_provider_error(command, stderr_byte_count)
          |> maybe_put_exit_code(result)

        if provider_error.code == "ALREADY_TERMINAL" do
          {:ok, :already_terminal}
        else
          {:error, provider_error}
        end

      :error ->
        case detect_already_closed_close_result(stdout, task_id) do
          {:ok, :already_terminal} ->
            {:ok, :already_terminal}

          :error ->
            {:error,
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
             |> maybe_put_exit_code(result)}
        end
    end
  end

  # `br close` on an already-closed issue writes two JSON objects to stdout:
  # a single-line `{"closed":[],"skipped":[{"id":<task_id>,"reason":"already closed"}]}`
  # followed by a multi-line `{"error":{...}}` envelope. `Jason.decode/1` cannot
  # parse the concatenated buffer (the envelope decoder returns :error), so
  # the only recoverable signal is the leading single-line JSON object. We
  # isolate it by taking the first non-empty line — this avoids any
  # string-unsafe brace/bracket counting inside the JSON payload.
  defp detect_already_closed_close_result(stdout, task_id)
       when is_binary(stdout) and is_binary(task_id) do
    case first_non_empty_line(stdout) do
      {:ok, line} ->
        case Jason.decode(line) do
          {:ok,
           %{
             "closed" => [],
             "skipped" => [%{"id" => ^task_id, "reason" => "already closed"}]
           }} ->
            {:ok, :already_terminal}

          _ ->
            :error
        end

      :error ->
        :error
    end
  end

  defp detect_already_closed_close_result(_stdout, _task_id), do: :error

  defp first_non_empty_line(stdout) do
    case String.split(stdout, "\n", parts: 2) do
      [line, _rest] ->
        trimmed = String.trim(line)

        if trimmed == "" do
          :error
        else
          {:ok, line}
        end

      _ ->
        :error
    end
  end

  defp build_complete_schema_validation_error(errors) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "SCHEMA_VALIDATION_FAILED",
        "Beads closed issue payload failed schema validation.",
        "Refresh the cached schema or re-fetch the Beads payload.",
        false,
        missing_fields_from(errors)
      ),
      "br close",
      0
    )
  end

  defp build_complete_contract_error(message) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_CONTRACT_MISMATCH",
        message,
        "Update the adapter or install a supported Beads CLI version.",
        false
      ),
      "br close",
      0
    )
  end

  defp build_complete_parse_error do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_PARSE_ERROR",
        "Beads closed issue payload could not be parsed.",
        "Check the Beads output format or refresh the CLI contract cache.",
        false
      ),
      "br close",
      0
    )
  end

  defp parse_failed_issue_response(stdout, task_id, argv) when is_binary(stdout) do
    case String.trim(stdout) do
      "" ->
        {:error, build_fail_parse_error(argv)}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = payload} ->
            parse_failed_issue_payload(payload, task_id, argv)

          {:ok, [%{} = payload]} ->
            parse_failed_issue_payload(payload, task_id, argv)

          {:ok, _other} ->
            {:error,
             build_fail_contract_error(
               "Beads failed issue payload must decode to a JSON object.",
               argv
             )}

          {:error, _reason} ->
            {:error, build_fail_parse_error(argv)}
        end
    end
  end

  defp parse_failed_issue_response(_stdout, _task_id, argv) do
    {:error, build_fail_parse_error(argv)}
  end

  defp parse_failed_issue_payload(payload, task_id, argv) when is_map(payload) do
    with :ok <- JsonSchemaCache.validate(:failed_issue, payload),
         {:ok, id} <- fetch_fail_required_string(payload, :id, argv),
         {:ok, title} <- fetch_fail_optional_string(payload, :title, task_id, argv),
         {:ok, priority} <- parse_fail_priority(fetch_payload_value(payload, :priority), argv),
         {:ok, dependencies} <-
           parse_fail_string_list(
             fetch_payload_value(payload, :dependencies),
             :dependencies,
             argv
           ),
         {:ok, assignee} <- fetch_fail_optional_string(payload, :assignee, nil, argv),
         {:ok, description} <- fetch_fail_optional_string(payload, :description, nil, argv),
         {:ok, notes} <- fetch_fail_optional_string(payload, :notes, nil, argv),
         {:ok, design} <- fetch_fail_optional_string(payload, :design, nil, argv),
         {:ok, labels} <-
           parse_fail_string_list(fetch_payload_value(payload, :labels), :labels, argv),
         {:ok, metadata} <- parse_fail_metadata(fetch_payload_value(payload, :metadata), argv) do
      TaskProviderTelemetry.emit(
        [:foreman_server, :task_provider, :beads_adapter, :fail, :success],
        %{system_time: System.system_time()},
        %{argv: argv}
      )

      {:ok,
       %Issue{
         id: id,
         title: title,
         status: "open",
         priority: priority,
         dependencies: dependencies,
         dependents: [],
         assignee: assignee,
         description: description,
         notes: notes,
         design: design,
         labels: labels,
         metadata: metadata
       }}
    else
      {:error, errors} when is_list(errors) ->
        {:error, build_fail_schema_validation_error(errors, argv)}

      {:error, provider_error} ->
        {:error, provider_error}
    end
  end

  defp fetch_fail_required_string(payload, key, argv) do
    case fetch_payload_value(payload, key) do
      value when is_binary(value) ->
        {:ok, value}

      _other ->
        {:error,
         build_fail_contract_error(
           "Beads failed issue field #{inspect(key)} must be a string.",
           argv
         )}
    end
  end

  defp fetch_fail_optional_string(payload, key, default, argv) do
    case fetch_payload_value(payload, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, build_fail_optional_string_error(key, argv)}
    end
  end

  defp build_fail_optional_string_error(key, argv) do
    build_fail_contract_error(
      "Beads failed issue field #{inspect(key)} must be a string or null.",
      argv
    )
  end

  defp parse_fail_priority(nil, _argv), do: {:ok, 0}
  defp parse_fail_priority(value, _argv) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_fail_priority(_value, argv) do
    {:error,
     build_fail_contract_error(
       "Beads failed issue field :priority must be a non-negative integer.",
       argv
     )}
  end

  defp parse_fail_string_list(nil, _field, _argv), do: {:ok, []}

  defp parse_fail_string_list(values, field, argv) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error,
       build_fail_contract_error(
         "Beads failed issue field #{inspect(field)} must be a list of strings.",
         argv
       )}
    end
  end

  defp parse_fail_string_list(_values, field, argv) do
    {:error,
     build_fail_contract_error(
       "Beads failed issue field #{inspect(field)} must be a list of strings.",
       argv
     )}
  end

  defp parse_fail_metadata(nil, _argv), do: {:ok, %{}}
  defp parse_fail_metadata(%{} = metadata, _argv), do: {:ok, metadata}

  defp parse_fail_metadata(_metadata, argv) do
    {:error,
     build_fail_contract_error("Beads failed issue field :metadata must be an object.", argv)}
  end

  defp build_fail_error(stdout, stderr, result, task_id, argv) do
    stderr_byte_count = byte_size(stderr)
    command = scrubbed_fail_command(argv)

    case parse_br_error_envelope(stderr, stdout) do
      {:ok, envelope} ->
        raw_code = normalize_provider_code(envelope[:code] || envelope["code"])

        provider_error =
          envelope
          |> ProviderErrorInput.from_br_envelope()
          |> CodeMap.build_provider_error(command, stderr_byte_count)
          |> maybe_put_exit_code(result)

        if provider_error.code == "BR_ERROR_ENVELOPE" do
          TaskProviderTelemetry.emit(
            [:foreman_server, :task_provider, :transition_comment, :rejected],
            %{system_time: System.system_time()},
            %{argv: argv, raw_code: raw_code, task_id: task_id}
          )

          Logger.warning(
            "BR_ERROR_ENVELOPE raw_code=#{raw_code} argv=#{inspect(TaskProviderTelemetry.scrub_argv(argv))}"
          )
        end

        {:error, provider_error}

      :error ->
        {:error,
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
         |> maybe_put_exit_code(result)}
    end
  end

  defp build_fail_schema_validation_error(errors, argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "VALIDATION_FAILED",
        "Beads fail payload failed schema validation.",
        "Refresh the cached schema or re-fetch the Beads payload.",
        false,
        missing_fields_from(errors)
      ),
      scrubbed_fail_command(argv),
      0
    )
  end

  defp build_fail_contract_error(message, argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_CONTRACT_MISMATCH",
        message,
        "Update the adapter or install a supported Beads CLI version.",
        false
      ),
      scrubbed_fail_command(argv),
      0
    )
  end

  defp build_fail_parse_error(argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_PARSE_ERROR",
        "Beads failed issue payload could not be parsed.",
        "Check the Beads output format or refresh the CLI contract cache.",
        false
      ),
      scrubbed_fail_command(argv),
      0
    )
  end

  defp resolve_transition_comment(%{} = failure_token) do
    case fetch_payload_value(failure_token, :transition_comment) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        fabricate_transition_comment(failure_token)
    end
  end

  defp resolve_transition_comment(value) when is_binary(value) and value != "", do: {:ok, value}

  defp resolve_transition_comment(failure_token) do
    fabricate_transition_comment(failure_token)
  end

  defp fabricate_transition_comment(%{} = failure_token) do
    case {fetch_payload_value(failure_token, :run_id),
          fetch_payload_value(failure_token, :artifact_path)} do
      {run_id, artifact_path}
      when is_binary(run_id) and run_id != "" and is_binary(artifact_path) and artifact_path != "" ->
        {:ok, "foreman-run:#{run_id}:#{artifact_path}"}

      _other ->
        {:error,
         CodeMap.build_provider_error(
           ProviderErrorInput.from_local(
             "INVALID_TRANSITION_COMMENT",
             "Transition comment must be a non-empty string.",
             "Pass :transition_comment or provide both :run_id and :artifact_path.",
             false
           ),
           nil,
           0
         )}
    end
  end

  defp fabricate_transition_comment(_failure_token) do
    {:error,
     CodeMap.build_provider_error(
       ProviderErrorInput.from_local(
         "INVALID_TRANSITION_COMMENT",
         "Transition comment must be a non-empty string.",
         "Pass :transition_comment or provide both :run_id and :artifact_path.",
         false
       ),
       nil,
       0
     )}
  end

  defp scrubbed_fail_command(argv) do
    argv
    |> TaskProviderTelemetry.scrub_argv()
    |> then(&["br" | &1])
    |> Enum.join(" ")
  end

  defp normalize_provider_code(code) when is_binary(code), do: code
  defp normalize_provider_code(code) when is_atom(code), do: Atom.to_string(code)
  defp normalize_provider_code(code), do: inspect(code)

  defp missing_fields_from(errors) when is_list(errors) do
    errors
    |> Enum.flat_map(fn
      %{path: [field | _rest], message: "is required"} -> [to_string(field)]
      _other -> []
    end)
    |> Enum.uniq()
  end

  @impl true
  def get(task_id, project_config) when is_map(project_config),
    do: get(project_config, task_id, [])

  def get(project_config, task_id) when is_map(project_config),
    do: get(project_config, task_id, [])

  def get(project_config, task_id, opts) when is_map(project_config) and is_list(opts) do
    if is_binary(task_id) and String.trim(task_id) != "" do
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

      request = {:show, %{id: task_id, database_path: database_path}}
      argv = ["show", "--db", database_path, task_id, "--json"]
      timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

      case @runner.cmd(request, project_config, timeout_ms: timeout_ms) do
        {:ok, %{stdout: stdout}} ->
          parse_get_issue_response(stdout, argv)

        {:error, %{stdout: stdout, stderr: stderr} = result} ->
          {:error, build_get_error(stdout, stderr, result, argv)}
      end
    else
      {:error,
       CodeMap.build_provider_error(
         ProviderErrorInput.from_local(
           "INVALID_TASK_ID",
           "Issue identifier must be a non-empty string.",
           "Pass a non-empty Beads issue identifier before retrying.",
           false
         ),
         nil,
         0
       )}
    end
  end

  defp parse_get_issue_response(stdout, argv) when is_binary(stdout) do
    case String.trim(stdout) do
      "" ->
        {:error, build_get_parse_error(argv)}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = payload} ->
            parse_get_issue_payload(payload, argv)

          {:ok, _other} ->
            {:error,
             build_get_contract_error(
               "Beads issue-details payload must decode to a JSON object.",
               argv
             )}

          {:error, _reason} ->
            {:error, build_get_parse_error(argv)}
        end
    end
  end

  defp parse_get_issue_response(_stdout, argv) do
    {:error, build_get_parse_error(argv)}
  end

  defp parse_get_issue_payload(%{} = payload, argv) do
    populate_issue_from_payload(payload, argv)
  end

  defp populate_issue_from_payload(payload, argv) do
    with :ok <- JsonSchemaCache.validate(:issue_details, payload),
         {:ok, id} <- fetch_required_string(payload, :id),
         {:ok, title} <- fetch_required_string(payload, :title),
         {:ok, status} <- fetch_required_string(payload, :status),
         {:ok, priority} <- parse_priority(fetch_payload_value(payload, :priority)),
         {:ok, dependencies} <-
           parse_get_dependencies(fetch_payload_value(payload, :dependencies), argv),
         {:ok, dependents} <-
           parse_get_issue_array(fetch_payload_value(payload, :dependents), :dependents, argv),
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
         status: status,
         priority: priority,
         dependencies: dependencies,
         dependents: dependents,
         assignee: assignee,
         description: description,
         notes: notes,
         design: design,
         labels: labels,
         metadata: metadata
       }}
    else
      {:error, errors} when is_list(errors) ->
        {:error, build_get_validation_error(errors, argv)}

      {:error, provider_error} ->
        {:error, provider_error}
    end
  end

  defp parse_get_dependencies(values, argv) when is_list(values) do
    parse_get_issue_array(values, :dependencies, argv)
  end

  defp parse_get_dependencies(_values, argv) do
    {:error,
     build_get_contract_error(
       "Beads issue-details field :dependencies must be a list of issue objects.",
       argv
     )}
  end

  defp parse_get_issue_array(values, field, argv) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      %{} = value, {:ok, issues} ->
        case parse_get_issue_reference(value, field, argv) do
          {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _value, _acc ->
        {:halt,
         {:error,
          build_get_contract_error(
            "Beads issue-details field #{inspect(field)} must be a list of issue objects.",
            argv
          )}}
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_get_issue_array(_values, field, argv) do
    {:error,
     build_get_contract_error(
       "Beads issue-details field #{inspect(field)} must be a list of issue objects.",
       argv
     )}
  end

  defp parse_get_issue_reference(%{} = payload, _field, argv) do
    populate_issue_from_payload(payload, argv)
  end

  defp build_get_error(stdout, stderr, result, argv) do
    stderr_byte_count = byte_size(stderr)
    command = scrubbed_get_command(argv)

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

  defp build_get_validation_error(errors, argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "VALIDATION_FAILED",
        "Beads issue-details payload failed schema validation.",
        "Refresh the cached schema or re-fetch the Beads payload.",
        false,
        missing_fields_from(errors)
      ),
      scrubbed_get_command(argv),
      0
    )
  end

  defp build_get_contract_error(message, argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_CONTRACT_MISMATCH",
        message,
        "Update the adapter or install a supported Beads CLI version.",
        false
      ),
      scrubbed_get_command(argv),
      0
    )
  end

  defp build_get_parse_error(argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_PARSE_ERROR",
        "Beads issue-details payload could not be parsed.",
        "Check the Beads output format or refresh the CLI contract cache.",
        false
      ),
      scrubbed_get_command(argv),
      0
    )
  end

  defp scrubbed_get_command(argv) do
    argv
    |> TaskProviderTelemetry.scrub_argv()
    |> then(&["br" | &1])
    |> Enum.join(" ")
  end

  @impl true
  def claim(task_id, actor, project_config) do
    if is_binary(task_id) and String.trim(task_id) != "" do
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

      run_id = Map.get(project_config, :run_id) || Map.get(project_config, "run_id") || ""

      if run_id == "" do
        raise ArgumentError, "expected project_config with :run_id for lease serialization"
      end

      request = {:update, %{flags: ["--claim", task_id]}}

      BeadsDbLease.with_lease(database_path, run_id, task_id, fn ->
        case @runner.cmd(request, project_config, timeout_ms: 30_000) do
          {:ok, %{stdout: stdout}} ->
            case String.trim(stdout) do
              "" ->
                {:error,
                 CodeMap.build_provider_error(
                   ProviderErrorInput.from_local(
                     "BR_PARSE_ERROR",
                     "Beads claim payload could not be parsed.",
                     "Check the Beads output format or refresh the CLI contract cache.",
                     false
                   ),
                   "br update",
                   0
                 )}

              json ->
                case Jason.decode(json) do
                  {:ok, [%{} = payload | _rest]} ->
                    parse_claimed_payload(payload, actor)

                  {:ok, %{} = payload} ->
                    parse_claimed_payload(payload, actor)

                  {:ok, _other} ->
                    {:error,
                     CodeMap.build_provider_error(
                       ProviderErrorInput.from_local(
                         "BR_CONTRACT_MISMATCH",
                         "Beads claim payload must decode to a JSON object or array.",
                         "Update the adapter or install a supported Beads CLI version.",
                         false
                       ),
                       "br update",
                       0
                     )}

                  {:error, _reason} ->
                    {:error,
                     CodeMap.build_provider_error(
                       ProviderErrorInput.from_local(
                         "BR_PARSE_ERROR",
                         "Beads claim payload could not be parsed.",
                         "Check the Beads output format or refresh the CLI contract cache.",
                         false
                       ),
                       "br update",
                       0
                     )}
                end
            end

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
      end)
    else
      {:error,
       CodeMap.build_provider_error(
         ProviderErrorInput.from_local(
           "INVALID_TASK_ID",
           "Issue identifier must be a non-empty string.",
           "Pass the Beads task identifier returned by the provider.",
           false
         ),
         nil,
         0
       )}
    end
  end

  defp parse_claimed_payload(payload, actor) do
    with :ok <- JsonSchemaCache.validate(:claimed_issue, payload),
         {:ok, id} <- fetch_required_string(payload, :id),
         {:ok, title} <- fetch_required_string(payload, :title),
         {:ok, _status} <- fetch_required_string(payload, :status),
         {:ok, priority} <- parse_priority(fetch_payload_value(payload, :priority)),
         {:ok, dependencies} <-
           parse_opaque_string_list(
             fetch_payload_value(payload, :dependencies),
             :dependencies
           ),
         {:ok, assignee} <-
           parse_optional_string(fetch_payload_value(payload, :assignee), :assignee),
         {:ok, description} <-
           parse_optional_string(
             fetch_payload_value(payload, :description),
             :description
           ),
         {:ok, notes} <-
           parse_optional_string(fetch_payload_value(payload, :notes), :notes),
         {:ok, design} <-
           parse_optional_string(fetch_payload_value(payload, :design), :design),
         {:ok, labels} <-
           parse_opaque_string_list(fetch_payload_value(payload, :labels), :labels),
         {:ok, metadata} <- parse_metadata(fetch_payload_value(payload, :metadata)) do
      {:ok,
       %Issue{
         id: id,
         title: title,
         status: "in_progress",
         priority: priority,
         dependencies: dependencies,
         dependents: [],
         assignee: if(is_binary(actor) and actor != "", do: actor, else: assignee),
         description: description,
         notes: notes,
         design: design,
         labels: labels,
         metadata: metadata
       }}
    else
      {:error, errors} when is_list(errors) ->
        {:error,
         CodeMap.build_provider_error(
           ProviderErrorInput.from_local(
             "SCHEMA_VALIDATION_FAILED",
             "Beads claimed issue payload failed schema validation.",
             "Refresh the cached schema or re-fetch the Beads payload.",
             false,
             missing_fields_from(errors)
           ),
           "br update",
           0
         )}

      {:error, provider_error} ->
        {:error, provider_error}
    end
  end

  @impl true
  def complete(task_id, completion_token, project_config) when is_map(project_config) do
    run_id = Map.get(project_config, :run_id)

    # Generate synthetic run_id when absent — callers without a bound run (e.g. direct
    # API calls, janitor) still need lease serialization to prevent concurrent writes.
    # Nanosecond + unique integer suffix guarantees uniqueness under concurrent calls
    # to the same project.
    resolved_run_id =
      if is_binary(run_id) and run_id != "" do
        run_id
      else
        "synthetic:#{task_id}:#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      end

    complete(task_id, completion_token, resolved_run_id, project_config)
  end

  # 4-arity: explicit run_id for callers (janitor) that need to serialize
  # their own writes independently of a task-bound run.
  def complete(task_id, completion_token, run_id, project_config)
      when is_map(project_config) and (is_binary(run_id) or is_nil(run_id)) do
    if is_binary(task_id) and String.trim(task_id) != "" do
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

      # 4-arity callers (janitor) must supply an explicit run_id.
      # Synthesizing silently here would mask a genuine caller defect.
      if is_binary(run_id) and run_id != "" do
        run_id
      else
        raise ArgumentError, "expected non-empty run_id for lease serialization"
      end

      resolved_run_id = run_id

      close_payload = build_close_payload(task_id, completion_token)

      BeadsDbLease.with_lease(database_path, resolved_run_id, task_id, fn ->
        case @runner.cmd({:close, close_payload}, %{database_path: database_path},
               timeout_ms: 30_000
             ) do
          {:ok, %{stdout: stdout}} ->
            parse_closed_issue_response(stdout, task_id)

          {:error, %{stdout: stdout, stderr: stderr} = result} ->
            build_complete_error(stdout, stderr, result, task_id)
        end
      end)
    else
      {:error,
       CodeMap.build_provider_error(
         ProviderErrorInput.from_local(
           "INVALID_TASK_ID",
           "Issue identifier must be a non-empty string.",
           "Pass the Beads task identifier returned by the provider.",
           false
         ),
         nil,
         0
       )}
    end
  end

  # TRD-008 contract reconciliation: `complete/3` honors a map-shaped
  # `completion_token` with a `:transition_comment` key (consumed by the
  # Actor's bounded-retry-exhaustion and post-reload re-decision compensation
  # paths in `ForemanServer.Aggregate.Actor`). When the token is not a map
  # (legacy atom/nil callers) the close payload is unchanged — pre-existing
  # `BeadsAdapterCompleteTest` assertions of `{:close, %{id: ...}}` remain
  # green. The `:reason` key is forwarded to `SystemBrRunner`, which
  # translates it to `br close --transition-comment <reason>`.
  defp build_close_payload(task_id, %{transition_comment: comment})
       when is_binary(comment) and comment != "" do
    %{id: task_id, reason: comment}
  end

  defp build_close_payload(task_id, _completion_token), do: %{id: task_id}

  @impl true
  def fail(task_id, failure_token, project_config) when is_map(project_config) do
    if is_binary(task_id) and String.trim(task_id) != "" do
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

      run_id = Map.get(project_config, :run_id) || Map.get(project_config, "run_id") || ""

      if run_id == "" do
        raise ArgumentError, "expected project_config with :run_id for lease serialization"
      end

      with {:ok, transition_comment} <- resolve_transition_comment(failure_token) do
        request =
          {:update,
           %{
             flags: [task_id, "--status", "open", "--transition-comment", transition_comment],
             database_path: database_path
           }}

        argv = [
          "update",
          "--db",
          database_path,
          task_id,
          "--status",
          "open",
          "--transition-comment",
          transition_comment,
          "--json"
        ]

        BeadsDbLease.with_lease(database_path, run_id, task_id, fn ->
          case @runner.cmd(request, %{database_path: database_path}, timeout_ms: 30_000) do
            {:ok, %{stdout: stdout}} ->
              parse_failed_issue_response(stdout, task_id, argv)

            {:error, %{stdout: stdout, stderr: stderr} = result} ->
              build_fail_error(stdout, stderr, result, task_id, argv)
          end
        end)
      end
    else
      {:error,
       CodeMap.build_provider_error(
         ProviderErrorInput.from_local(
           "INVALID_TASK_ID",
           "Issue identifier must be a non-empty string.",
           "Pass the Beads task identifier returned by the provider.",
           false
         ),
         nil,
         0
       )}
    end
  end

  @impl true
  def reopen(task_id, transition_comment, project_config) when is_map(project_config) do
    if is_binary(task_id) and String.trim(task_id) != "" do
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

      with {:ok, reopen_comment} <- resolve_transition_comment(transition_comment) do
        request =
          {:update,
           %{
             flags: [task_id, "--status", "open", "--transition-comment", reopen_comment],
             database_path: database_path
           }}

        argv = [
          "update",
          "--db",
          database_path,
          task_id,
          "--status",
          "open",
          "--transition-comment",
          reopen_comment,
          "--json"
        ]

        case @runner.cmd(request, %{database_path: database_path}, timeout_ms: 30_000) do
          {:ok, %{stdout: stdout}} ->
            parse_reopened_issue_response(stdout, task_id, argv)

          {:error, %{stdout: stdout, stderr: stderr} = result} ->
            build_reopen_error(stdout, stderr, result, argv)
        end
      end
    else
      {:error,
       CodeMap.build_provider_error(
         ProviderErrorInput.from_local(
           "INVALID_TASK_ID",
           "Issue identifier must be a non-empty string.",
           "Pass the Beads task identifier returned by the provider.",
           false
         ),
         nil,
         0
       )}
    end
  end

  defp parse_reopened_issue_response(stdout, task_id, argv) when is_binary(stdout) do
    case String.trim(stdout) do
      "" ->
        {:error, build_reopen_parse_error(argv)}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = payload} ->
            parse_reopened_issue_payload(payload, task_id, argv)

          {:ok, [%{} = payload]} ->
            parse_reopened_issue_payload(payload, task_id, argv)

          {:ok, _other} ->
            {:error,
             build_reopen_contract_error(
               "Beads reopened issue payload must decode to a JSON object.",
               argv
             )}

          {:error, _reason} ->
            {:error, build_reopen_parse_error(argv)}
        end
    end
  end

  defp parse_reopened_issue_response(_stdout, _task_id, argv) do
    {:error, build_reopen_parse_error(argv)}
  end

  defp parse_reopened_issue_payload(payload, task_id, argv) when is_map(payload) do
    with :ok <- JsonSchemaCache.validate(:reopened_issue, payload),
         {:ok, id} <- fetch_reopen_required_string(payload, :id, argv),
         {:ok, title} <- fetch_reopen_optional_string(payload, :title, task_id, argv),
         {:ok, priority} <- parse_reopen_priority(fetch_payload_value(payload, :priority), argv),
         {:ok, dependencies} <-
           parse_reopen_string_list(
             fetch_payload_value(payload, :dependencies),
             :dependencies,
             argv
           ),
         {:ok, assignee} <- fetch_reopen_optional_string(payload, :assignee, nil, argv),
         {:ok, description} <- fetch_reopen_optional_string(payload, :description, nil, argv),
         {:ok, notes} <- fetch_reopen_optional_string(payload, :notes, nil, argv),
         {:ok, design} <- fetch_reopen_optional_string(payload, :design, nil, argv),
         {:ok, labels} <-
           parse_reopen_string_list(fetch_payload_value(payload, :labels), :labels, argv),
         {:ok, metadata} <- parse_reopen_metadata(fetch_payload_value(payload, :metadata), argv) do
      {:ok,
       %Issue{
         id: id,
         title: title,
         status: "open",
         priority: priority,
         dependencies: dependencies,
         dependents: [],
         assignee: assignee,
         description: description,
         notes: notes,
         design: design,
         labels: labels,
         metadata: metadata
       }}
    else
      {:error, errors} when is_list(errors) ->
        {:error, build_reopen_schema_validation_error(errors, argv)}

      {:error, provider_error} ->
        {:error, provider_error}
    end
  end

  defp fetch_reopen_required_string(payload, key, argv) do
    case fetch_payload_value(payload, key) do
      value when is_binary(value) ->
        {:ok, value}

      _other ->
        {:error,
         build_reopen_contract_error(
           "Beads reopened issue field #{inspect(key)} must be a string.",
           argv
         )}
    end
  end

  defp fetch_reopen_optional_string(payload, key, default, argv) do
    case fetch_payload_value(payload, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, build_reopen_optional_string_error(key, argv)}
    end
  end

  defp build_reopen_optional_string_error(key, argv) do
    build_reopen_contract_error(
      "Beads reopened issue field #{inspect(key)} must be a string or null.",
      argv
    )
  end

  defp parse_reopen_priority(nil, _argv), do: {:ok, 0}
  defp parse_reopen_priority(value, _argv) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_reopen_priority(_value, argv) do
    {:error,
     build_reopen_contract_error(
       "Beads reopened issue field :priority must be a non-negative integer.",
       argv
     )}
  end

  defp parse_reopen_string_list(nil, _field, _argv), do: {:ok, []}

  defp parse_reopen_string_list(values, field, argv) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error,
       build_reopen_contract_error(
         "Beads reopened issue field #{inspect(field)} must be a list of strings.",
         argv
       )}
    end
  end

  defp parse_reopen_string_list(_values, field, argv) do
    {:error,
     build_reopen_contract_error(
       "Beads reopened issue field #{inspect(field)} must be a list of strings.",
       argv
     )}
  end

  defp parse_reopen_metadata(nil, _argv), do: {:ok, %{}}
  defp parse_reopen_metadata(%{} = metadata, _argv), do: {:ok, metadata}

  defp parse_reopen_metadata(_metadata, argv) do
    {:error,
     build_reopen_contract_error("Beads reopened issue field :metadata must be an object.", argv)}
  end

  defp build_reopen_error(stdout, stderr, result, argv) do
    stderr_byte_count = byte_size(stderr)
    command = scrubbed_reopen_command(argv)

    case parse_br_error_envelope(stderr, stdout) do
      {:ok, envelope} ->
        provider_error =
          envelope
          |> ProviderErrorInput.from_br_envelope()
          |> CodeMap.build_provider_error(command, stderr_byte_count)
          |> maybe_put_exit_code(result)

        if provider_error.code == "ALREADY_TERMINAL" do
          {:ok, :already_terminal}
        else
          {:error, provider_error}
        end

      :error ->
        {:error,
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
         |> maybe_put_exit_code(result)}
    end
  end

  defp build_reopen_schema_validation_error(errors, argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "VALIDATION_FAILED",
        "Beads reopened issue payload failed schema validation.",
        "Refresh the cached schema or re-fetch the Beads payload.",
        false,
        missing_fields_from(errors)
      ),
      scrubbed_reopen_command(argv),
      0
    )
  end

  defp build_reopen_contract_error(message, argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_CONTRACT_MISMATCH",
        message,
        "Update the adapter or install a supported Beads CLI version.",
        false
      ),
      scrubbed_reopen_command(argv),
      0
    )
  end

  defp build_reopen_parse_error(argv) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_PARSE_ERROR",
        "Beads reopened issue payload could not be parsed.",
        "Check the Beads output format or refresh the CLI contract cache.",
        false
      ),
      scrubbed_reopen_command(argv),
      0
    )
  end

  defp scrubbed_reopen_command(argv) do
    argv
    |> TaskProviderTelemetry.scrub_argv()
    |> then(&["br" | &1])
    |> Enum.join(" ")
  end

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
  def add_dependency(dependent_id, dependency_id, project_config) do
    add_dependency(dependent_id, dependency_id, project_config, [])
  end

  def add_dependency(dependent_id, dependency_id, project_config, opts)
      when is_map(project_config) and is_list(opts) do
    cond do
      not (is_binary(dependent_id) and String.trim(dependent_id) != "") ->
        {:error,
         CodeMap.build_provider_error(
           ProviderErrorInput.from_local(
             "INVALID_TASK_ID",
             "Issue identifier must be a non-empty string.",
             "Pass the Beads task identifier returned by the provider.",
             false
           ),
           nil,
           0
         )}

      not (is_binary(dependency_id) and String.trim(dependency_id) != "") ->
        {:error,
         CodeMap.build_provider_error(
           ProviderErrorInput.from_local(
             "INVALID_TASK_ID",
             "Issue identifier must be a non-empty string.",
             "Pass the Beads task identifier returned by the provider.",
             false
           ),
           nil,
           0
         )}

      not Regex.match?(@id_format_regex, dependency_id) ->
        {:error,
         CodeMap.build_provider_error(
           ProviderErrorInput.from_local(
             "INVALID_TASK_ID",
             "Dependency issue identifier must match the Beads id_format regex.",
             "Pass a dependency identifier matching #{@id_format_source}.",
             false
           ),
           nil,
           0
         )}

      dependent_id == dependency_id ->
        {:error,
         CodeMap.build_provider_error(
           ProviderErrorInput.from_local(
             "DEPENDENCY_CYCLE",
             "Dependency edge would create a cycle.",
             "Choose a dependency that does not reference the issue itself or any of its descendants.",
             false
           ),
           nil,
           0
         )}

      true ->
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

        request =
          {:add_dependency, %{dependent_id: dependent_id, dependency_id: dependency_id}}

        case @runner.cmd(
               request,
               %{database_path: database_path},
               Keyword.put_new(opts, :timeout_ms, 30_000)
             ) do
          {:ok, %{stdout: stdout}} ->
            parse_updated_issue_response(stdout, dependency_id)

          {:error, %{stdout: stdout, stderr: stderr} = result} ->
            {:error, build_add_dependency_error(stdout, stderr, result)}
        end
    end
  end

  defp parse_updated_issue_response(stdout, dependency_id) when is_binary(stdout) do
    case String.trim(stdout) do
      "" ->
        {:error, build_add_dependency_parse_error()}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = payload} ->
            parse_updated_issue_payload(payload, dependency_id)

          {:ok, [%{} = payload]} ->
            parse_updated_issue_payload(payload, dependency_id)

          {:ok, _other} ->
            {:error,
             build_add_dependency_contract_error(
               "Beads updated issue payload must decode to a JSON object."
             )}

          {:error, _reason} ->
            {:error, build_add_dependency_parse_error()}
        end
    end
  end

  defp parse_updated_issue_response(_stdout, _dependency_id) do
    {:error, build_add_dependency_parse_error()}
  end

  defp parse_updated_issue_payload(payload, dependency_id) when is_map(payload) do
    with :ok <- JsonSchemaCache.validate(:updated_issue, payload),
         {:ok, id} <- fetch_add_dependency_required_string(payload, :id),
         {:ok, title} <- fetch_add_dependency_required_string(payload, :title),
         {:ok, status} <- fetch_add_dependency_required_string(payload, :status),
         {:ok, priority} <-
           parse_add_dependency_priority(fetch_payload_value(payload, :priority)),
         {:ok, dependencies} <-
           parse_add_dependency_string_list(
             fetch_payload_value(payload, :dependencies),
             :dependencies
           ),
         {:ok, assignee} <-
           fetch_add_dependency_optional_string(payload, :assignee, nil),
         {:ok, description} <-
           fetch_add_dependency_optional_string(payload, :description, nil),
         {:ok, notes} <- fetch_add_dependency_optional_string(payload, :notes, nil),
         {:ok, design} <- fetch_add_dependency_optional_string(payload, :design, nil),
         {:ok, labels} <-
           parse_add_dependency_string_list(fetch_payload_value(payload, :labels), :labels),
         {:ok, metadata} <-
           parse_add_dependency_metadata(fetch_payload_value(payload, :metadata)) do
      {:ok,
       %Issue{
         id: id,
         title: title,
         status: status,
         priority: priority,
         dependencies: [dependency_id | Enum.reject(dependencies, &(&1 == dependency_id))],
         dependents: [],
         assignee: assignee,
         description: description,
         notes: notes,
         design: design,
         labels: labels,
         metadata: metadata
       }}
    else
      {:error, errors} when is_list(errors) ->
        {:error, build_add_dependency_validation_error(errors)}

      {:error, provider_error} ->
        {:error, provider_error}
    end
  end

  defp fetch_add_dependency_required_string(payload, key) do
    case fetch_payload_value(payload, key) do
      value when is_binary(value) ->
        {:ok, value}

      _other ->
        {:error,
         build_add_dependency_contract_error(
           "Beads updated issue field #{inspect(key)} must be a string."
         )}
    end
  end

  defp fetch_add_dependency_optional_string(payload, key, default) do
    case fetch_payload_value(payload, key) do
      nil ->
        {:ok, default}

      value when is_binary(value) ->
        {:ok, value}

      _other ->
        {:error,
         build_add_dependency_contract_error(
           "Beads updated issue field #{inspect(key)} must be a string or null."
         )}
    end
  end

  defp parse_add_dependency_priority(nil), do: {:ok, 0}

  defp parse_add_dependency_priority(value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp parse_add_dependency_priority(_value) do
    {:error,
     build_add_dependency_contract_error(
       "Beads updated issue field :priority must be a non-negative integer."
     )}
  end

  defp parse_add_dependency_string_list(nil, _field), do: {:ok, []}

  defp parse_add_dependency_string_list(values, field) when is_list(values) do
    if Enum.all?(values, &is_binary/1) do
      {:ok, values}
    else
      {:error,
       build_add_dependency_contract_error(
         "Beads updated issue field #{inspect(field)} must be a list of strings."
       )}
    end
  end

  defp parse_add_dependency_string_list(_values, field) do
    {:error,
     build_add_dependency_contract_error(
       "Beads updated issue field #{inspect(field)} must be a list of strings."
     )}
  end

  defp parse_add_dependency_metadata(nil), do: {:ok, %{}}
  defp parse_add_dependency_metadata(%{} = metadata), do: {:ok, metadata}

  defp parse_add_dependency_metadata(_metadata) do
    {:error,
     build_add_dependency_contract_error("Beads updated issue field :metadata must be an object.")}
  end

  defp build_add_dependency_error(stdout, stderr, result) do
    stderr_byte_count = byte_size(stderr)
    command = "br dep add"

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

  defp build_add_dependency_validation_error(errors) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "VALIDATION_FAILED",
        "Beads updated issue payload failed schema validation.",
        "Refresh the cached schema or re-fetch the Beads payload.",
        false,
        missing_fields_from(errors)
      ),
      "br dep add",
      0
    )
  end

  defp build_add_dependency_contract_error(message) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_CONTRACT_MISMATCH",
        message,
        "Update the adapter or install a supported Beads CLI version.",
        false
      ),
      "br dep add",
      0
    )
  end

  defp build_add_dependency_parse_error do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "BR_PARSE_ERROR",
        "Beads updated issue payload could not be parsed.",
        "Check the Beads output format or refresh the CLI contract cache.",
        false
      ),
      "br dep add",
      0
    )
  end

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

  # --- create/2 helpers (TRD-003-TASK) ----------------------------------------

  defp validate_create_attrs(attrs) do
    cond do
      not is_binary(Map.get(attrs, :title)) or Map.get(attrs, :title) in [nil, ""] ->
        {:error, invalid_title_error("Bead title must be a non-empty binary.")}

      not is_binary(Map.get(attrs, :task_id)) or Map.get(attrs, :task_id) in [nil, ""] ->
        {:error,
         invalid_title_error(
           "BeadsAdapter.create/2 requires a non-empty :task_id correlation handle."
         )}

      not is_binary(Map.get(attrs, :command_id)) or Map.get(attrs, :command_id) in [nil, ""] ->
        {:error,
         invalid_title_error(
           "BeadsAdapter.create/2 requires a non-empty :command_id correlation handle."
         )}

      true ->
        validate_create_attrs_priority_and_type(attrs)
    end
  end

  defp validate_create_attrs_priority_and_type(attrs) do
    priority = Map.get(attrs, :priority)
    task_type = Map.get(attrs, :task_type)

    cond do
      not is_integer(priority) or priority not in 0..4 ->
        {:error, invalid_priority_error(priority)}

      not is_binary(task_type) or task_type not in @valid_task_types ->
        {:error, invalid_issue_type_error(task_type)}

      true ->
        :ok
    end
  end

  defp invalid_title_error(message) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "INVALID_TITLE",
        message,
        "Pass a non-empty title or correlation handle before retrying.",
        false
      ),
      nil,
      0
    )
  end

  defp invalid_priority_error(got) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "INVALID_PRIORITY",
        "Issue priority must be between 0 and 4.",
        "Pass a Beads priority level in the inclusive range 0..4 (got: #{inspect(got)}).",
        false
      ),
      nil,
      0
    )
  end

  defp invalid_issue_type_error(got) do
    CodeMap.build_provider_error(
      ProviderErrorInput.from_local(
        "INVALID_ISSUE_TYPE",
        "Issue type must be one of: #{Enum.join(@valid_task_types, ", ")}.",
        "Pass a closed-enum task_type (got: #{inspect(got)}).",
        false
      ),
      nil,
      0
    )
  end

  defp resolve_project_config(project_id) do
    case ForemanServer.TaskProvider.Registry.project_config(project_id) do
      {:ok, %{config: config}} when is_map(config) ->
        case fetch_database_path(config) do
          {:ok, db_path} ->
            {:ok, %{database_path: db_path}}

          :error ->
            {:error, registry_config_error(project_id, :missing_database_path)}
        end

      {:error, reason} ->
        {:error, registry_config_error(project_id, reason)}
    end
  end

  defp registry_config_error(project_id, reason) do
    input =
      ProviderErrorInput.from_local(
        "CREATE_FAILED",
        "registry config unresolved",
        "Failed to resolve project config for #{project_id}",
        false
      )

    base = CodeMap.build_create_provider_error(input, nil, 0)
    enriched = base.context |> Map.put(:project_id, project_id) |> Map.put(:reason, reason)
    %{base | context: enriched}
  end

  # Accept both atom and string key shapes for the registry's `config` map.
  # The ProjectProviderProjector documents that "both string- and atom-keyed
  # maps are supported" (`project_provider_projector.ex` lines 91–97), so the
  # downstream consumer must tolerate either shape rather than rejecting one.
  defp fetch_database_path(%{database_path: db_path}) when is_binary(db_path) and db_path != "",
    do: {:ok, db_path}

  defp fetch_database_path(%{"database_path" => db_path})
       when is_binary(db_path) and db_path != "",
       do: {:ok, db_path}

  defp fetch_database_path(_config), do: :error

  defp build_create_payload(attrs) do
    description = Map.get(attrs, :description) || ""
    task_type = Map.get(attrs, :task_type)
    dedupe_key = Map.get(attrs, :dedupe_key)

    agent_context =
      Jason.encode!(%{
        foreman: %{
          task_id: Map.fetch!(attrs, :task_id),
          command_id: Map.fetch!(attrs, :command_id),
          origin: "foreman",
          linked_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })

    base_payload =
      Map.merge(
        %{description: description, agent_context: agent_context},
        %{
          title: Map.fetch!(attrs, :title),
          type: task_type,
          priority: Map.fetch!(attrs, :priority)
        }
      )

    if is_binary(dedupe_key) and dedupe_key != "" do
      Map.put(base_payload, :dedupe_key, dedupe_key)
    else
      base_payload
    end
  end

  defp run_create(project_id, project_config, payload) do
    case @runner.cmd({:create, payload}, project_config, timeout_ms: 30_000) do
      {:ok, %{stdout: stdout}} ->
        parse_create_response(stdout, project_id)

      {:error, %{stdout: stdout, stderr: stderr} = result} ->
        {:error, build_create_error(stdout, stderr, result)}
    end
  end

  defp parse_create_response(stdout, project_id) when is_binary(stdout) do
    case String.trim(stdout) do
      "" ->
        {:error, build_create_parse_error("br create", project_id)}

      json ->
        case Jason.decode(json) do
          {:ok, %{} = payload} ->
            build_issue_from_create_payload(payload, project_id)

          {:ok, _other} ->
            {:error,
             build_create_contract_error(
               "Beads create payload must decode to a JSON object.",
               project_id
             )}

          {:error, _reason} ->
            {:error, build_create_parse_error("br create", project_id)}
        end
    end
  end

  defp parse_create_response(_stdout, project_id) do
    {:error, build_create_parse_error("br create", project_id)}
  end

  defp build_issue_from_create_payload(payload, project_id) do
    with {:ok, id} <- fetch_required_create_string(payload, :id),
         {:ok, title} <- fetch_required_create_string(payload, :title),
         {:ok, priority} <- parse_create_priority(payload_value(payload, :priority)) do
      status = to_string(payload_value(payload, :status) || "open")
      description = payload_string(payload, :description)
      now_ms = System.system_time(:millisecond)

      base_metadata = %{
        foreman_project_id: project_id,
        foreman_created_at_ms: now_ms,
        foreman_origin: "foreman",
        source_repo: derive_source_repo(payload),
        issue_type: payload_value(payload, :issue_type) || payload_value(payload, :type),
        labels: extract_labels(payload)
      }

      issue = %Issue{
        id: id,
        title: title,
        status: status,
        priority: priority,
        dependencies: [],
        dependents: [],
        assignee: nil,
        description: description,
        notes: nil,
        design: nil,
        labels: extract_labels(payload),
        metadata: base_metadata
      }

      {:ok, issue}
    end
  end

  # Normalize string-or-atom key map access (Jason.decode/1 returns string keys).
  defp payload_value(payload, key) when is_map(payload) and is_atom(key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_string(payload, key) when is_map(payload) and is_atom(key) do
    case payload_value(payload, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp fetch_required_create_string(payload, key) do
    case Map.get(payload, key) || Map.get(payload, Atom.to_string(key)) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        {:error,
         build_create_contract_error("Missing required string field #{inspect(key)}.", nil)}
    end
  end

  defp parse_create_priority(value) when is_integer(value) and value in 0..4, do: {:ok, value}

  defp parse_create_priority(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int in 0..4 -> {:ok, int}
      _ -> {:ok, 2}
    end
  end

  defp parse_create_priority(_other), do: {:ok, 2}

  defp derive_source_repo(payload) do
    case Map.get(payload, :agent_context) || Map.get(payload, "agent_context") do
      %{"foreman" => %{"task_id" => task_id}} when is_binary(task_id) ->
        "foreman:#{task_id}"

      _ ->
        nil
    end
  end

  defp extract_labels(payload) do
    case Map.get(payload, :labels) || Map.get(payload, "labels") do
      labels when is_list(labels) ->
        Enum.filter(labels, &is_binary/1)

      _ ->
        []
    end
  end

  defp build_create_error(stdout, stderr, result) do
    stderr_byte_count = byte_size(stderr)
    command = "br create"

    provider_error =
      case parse_br_error_envelope(stderr, stdout) do
        {:ok, envelope} ->
          envelope
          |> ProviderErrorInput.from_br_envelope()
          |> CodeMap.build_create_provider_error(command, stderr_byte_count)

        :error ->
          CodeMap.build_create_provider_error(
            ProviderErrorInput.from_local(
              "BR_PARSE_ERROR",
              "Beads CLI returned an unreadable create envelope.",
              "Verify the installed br version and retry the create operation.",
              false
            ),
            command,
            stderr_byte_count
          )
      end
      |> maybe_put_exit_code(result)

    provider_error
  end

  defp build_create_parse_error(command, _project_id) do
    CodeMap.build_create_provider_error(
      ProviderErrorInput.from_local(
        "BR_PARSE_ERROR",
        "Beads create payload could not be parsed.",
        "Check the Beads output format or refresh the CLI contract cache.",
        false
      ),
      command,
      0
    )
  end

  defp build_create_contract_error(message, _project_id) do
    CodeMap.build_create_provider_error(
      ProviderErrorInput.from_local(
        "BR_CONTRACT_MISMATCH",
        message,
        "Update the adapter or install a supported Beads CLI version.",
        false
      ),
      "br create",
      0
    )
  end

  defp emit_create_start(project_id, attrs) do
    TaskProviderTelemetry.emit(
      [:foreman_server, :task_provider, :beads_adapter, :create, :start],
      %{system_time: System.system_time()},
      %{
        project_id: project_id,
        title: Map.get(attrs, :title),
        task_type: Map.get(attrs, :task_type),
        priority: Map.get(attrs, :priority)
      }
    )

    :ok
  end

  defp emit_create_ok(project_id, _attrs, issue) do
    TaskProviderTelemetry.emit(
      [:foreman_server, :task_provider, :beads_adapter, :create, :ok],
      %{system_time: System.system_time()},
      %{project_id: project_id, issue_id: issue.id}
    )

    :ok
  end

  defp emit_create_error(project_id, _attrs, provider_error) do
    TaskProviderTelemetry.emit(
      [:foreman_server, :task_provider, :beads_adapter, :create, :error],
      %{system_time: System.system_time()},
      %{project_id: project_id, error: provider_error}
    )

    :ok
  end
end
