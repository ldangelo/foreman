defmodule ForemanServer.TaskProviders.JsonSchemaCache do
  @moduledoc """
  Caches `br schema ... --json` payload schemas for the Beads task provider.
  """

  use GenServer

  require Logger

  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry
  alias __MODULE__.State

  @br_runner Application.compile_env(
               :foreman_server,
               :br_runner,
               ForemanServer.TaskProviders.SystemBrRunner
             )
  @name :foreman_server_json_schema_cache
  @default_refresh_interval_ms 24 * 60 * 60 * 1000
  @refresh_event [:foreman_server, :task_provider, :beads, :capabilities, :refreshed]
  @version_changed_event [:foreman_server, :task_provider, :beads, :contract, :version_changed]

  # The real `br close --json` output is `{id, title, status, closed_at, close_reason}`.
  # br does not publish a separate `closed-issue` schema and this shape does NOT match
  # `:ready_issue` (which requires priority, issue_type, created_at, updated_at, etc.).
  # We pin the expected close-ack shape here so the validate(:closed_issue, payload)
  # TRD-mandated contract rejects drift instead of silently accepting garbage.
  @closed_issue_schema %{
    "$schema" => "https://json-schema.org/draft/2020-12/schema",
    "title" => "BeadsClosedIssue",
    "description" => "br close --json acknowledgement payload (minimal contract)",
    "type" => "object",
    "required" => ["id", "title", "status"],
    "properties" => %{
      "id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "status" => %{"type" => "string", "enum" => ["closed"]},
      "closed_at" => %{"type" => "string"},
      "close_reason" => %{"type" => ["string", "null"]}
    }
  }

  # Real `br update --json` (claim, reopen, status change) prints only
  # `{assignee, id, owner, priority, status, title, updated_at}` - verbatim in
  # test/fixtures/br/update_*.json - so br's published `ReadyIssue`/`IssueDetails`
  # schemas (which require created_at, issue_type, ...) can never be satisfied by
  # it. Pin the acknowledgement contracts the adapter actually relies on: the
  # `claim` and `add_dependency` parsers require `id`, `title` and `status`.
  @update_ack_schema %{
    "title" => "BeadsUpdateAck",
    "required" => ["id", "title", "status"],
    "properties" => %{
      "id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "status" => %{"type" => "string"},
      "priority" => %{"type" => "integer"},
      "assignee" => %{"type" => ["string", "null"]}
    }
  }

  # The `fail` and `reopen` parsers require only `id` (title falls back to the
  # request when absent).
  @transition_ack_schema %{
    "title" => "BeadsTransitionAck",
    "required" => ["id"],
    "properties" => %{
      "id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "status" => %{"type" => "string"},
      "priority" => %{"type" => "integer"}
    }
  }

  # `dependencies`/`dependents` items in `br show --json` are
  # `{dependency_type, id, priority, status, title}` (test/fixtures/br/show_*.json),
  # not the full `IssueDetails` the schema's `IssueWithDependencyMetadata` claims.
  @issue_reference_schema %{
    "title" => "BeadsIssueReference",
    "required" => ["id", "title", "status"],
    "properties" => %{
      "id" => %{"type" => "string"},
      "title" => %{"type" => "string"},
      "status" => %{"type" => "string"},
      "priority" => %{"type" => "integer"}
    }
  }

  @schema_requests %{
    ready_issue: "ready-issue",
    issue_details: "issue-details",
    error: "error",
    commands: "commands"
  }

  @schema_titles %{
    ready_issue: "ReadyIssue",
    issue_details: "IssueDetails",
    error: "ErrorEnvelope"
  }

  defmodule State do
    @enforce_keys []
    defstruct schemas: %{},
              version: nil,
              last_refresh: nil,
              refresh_interval_ms: 24 * 60 * 60 * 1000
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec validate(
          :commands
          | :ready_issue
          | :claimed_issue
          | :issue_details
          | :closed_issue
          | :failed_issue
          | :reopened_issue
          | :issue_reference,
          term()
        ) ::
          :ok | {:error, [map()]}
  def validate(schema_atom, payload)
      when schema_atom in [
             :commands,
             :ready_issue,
             :claimed_issue,
             :issue_details,
             :closed_issue,
             :failed_issue,
             :reopened_issue,
             :issue_reference
           ] do
    normalized_schema =
      case schema_atom do
        :commands -> :commands
        :claimed_issue -> :update_ack
        schema when schema in [:failed_issue, :reopened_issue] -> :transition_ack
        other -> other
      end

    GenServer.call(@name, {:validate, normalized_schema, payload})
  end

  def validate(schema_atom, _payload) do
    {:error, [%{path: [], message: "unsupported schema #{inspect(schema_atom)}"}]}
  end

  @impl true
  def init(opts) do
    state =
      %State{
        refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, @default_refresh_interval_ms)
      }
      |> load_schemas()

    schedule_refresh(state.refresh_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  def handle_call({:validate, schema, payload}, _from, state) do
    {:reply, validate_internal(schema, payload, state), state}
  end

  @impl true
  def handle_info(:refresh, state) do
    case fetch_schemas(state) do
      {:ok, new_state} ->
        emit_refresh_telemetry(new_state)
        maybe_emit_version_change(state.version, new_state.version)
        schedule_refresh(new_state.refresh_interval_ms)
        {:noreply, new_state}

      {:error, same_state} ->
        schedule_refresh(same_state.refresh_interval_ms)
        {:noreply, same_state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp load_schemas(state) do
    case fetch_schemas(state) do
      {:ok, new_state} -> new_state
      {:error, same_state} -> same_state
    end
  end

  defp fetch_schemas(%State{} = state) do
    case fetch_schema_documents() do
      {:ok, schemas} ->
        {:ok,
         %State{
           state
           | schemas: schemas,
             version: detect_contract_version(schemas) || state.version,
             last_refresh: DateTime.utc_now()
         }}

      {:error, reason} ->
        Logger.warning("JsonSchemaCache refresh failed: #{inspect(reason)}")
        {:error, state}
    end
  end

  defp fetch_schema_documents do
    {@schema_requests, {[], %{}}}
    |> then(fn {requests, acc} ->
      Enum.reduce(requests, acc, fn {schema_atom, schema_name}, {errors, schemas} ->
        case fetch_schema_document(schema_atom, schema_name) do
          {:ok, schema} ->
            {errors, Map.put(schemas, schema_atom, schema)}

          {:error, reason} ->
            {[reason | errors], schemas}
        end
      end)
    end)
    |> case do
      {[], schemas} -> {:ok, schemas}
      {errors, _schemas} -> {:error, Enum.reverse(errors)}
    end
  end

  defp fetch_schema_document(schema_atom, schema_name) do
    case @br_runner.cmd({:schema, %{schema: schema_name}}, %{}, []) do
      {:ok, %{stdout: json}} ->
        case Jason.decode(json) do
          {:ok, schema} when is_map(schema) ->
            {:ok, schema}

          {:ok, other} ->
            {:error, {:invalid_schema_document, schema_atom, other}}

          {:error, reason} ->
            {:error, {:invalid_json, schema_atom, reason}}
        end

      {:error, reason} ->
        {:error, {:schema_fetch_failed, schema_atom, reason}}

      other ->
        {:error, {:unexpected_runner_response, schema_atom, other}}
    end
  end

  defp validate_internal(schema_atom, payload, %State{} = state) do
    with {:ok, document} <- fetch_schema(state, schema_atom),
         {:ok, schema} <- enforcement_schema(schema_atom, document),
         :ok <- ensure_object_payload(payload) do
      errors = required_errors(schema, payload) ++ type_errors(schema, payload)

      if errors == [] do
        :ok
      else
        {:error, errors}
      end
    end
  end

  defp fetch_schema(_state, :closed_issue), do: {:ok, @closed_issue_schema}
  defp fetch_schema(_state, :update_ack), do: {:ok, @update_ack_schema}
  defp fetch_schema(_state, :transition_ack), do: {:ok, @transition_ack_schema}
  defp fetch_schema(_state, :issue_reference), do: {:ok, @issue_reference_schema}

  defp fetch_schema(%State{schemas: schemas}, schema_atom) do
    case Map.fetch(schemas, schema_atom) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, [%{path: [], message: "schema not loaded"}]}
    end
  end

  # `br schema <name> --json` does not return a bare JSON Schema. br 0.6.0 wraps
  # it: `{"tool", "generated_at", "schemas" => %{"ReadyIssue" => <schema>}}`
  # (verbatim in test/fixtures/br/schema_*.json), and `br schema commands` is a
  # command inventory with no schema at all. `required_errors/2` and
  # `type_errors/2` read top-level `required`/`properties`, which the wrapper
  # does not have, so validation against the unwrapped document accepted every
  # payload (foreman-mlklw). Select the definition the wrapper carries; a
  # wrapper without it is an error, never a silent pass.
  defp enforcement_schema(:commands, %{"commands" => commands}) when is_map(commands) do
    {:ok,
     %{
       "required" => ["commands"],
       "properties" => %{"commands" => %{"type" => "object"}}
     }}
  end

  defp enforcement_schema(schema_atom, %{"schemas" => schemas}) when is_map(schemas) do
    title = Map.get(@schema_titles, schema_atom)

    case Map.fetch(schemas, title) do
      {:ok, schema} when is_map(schema) ->
        {:ok, schema}

      _ ->
        {:error, [%{path: [], message: "schema document has no #{inspect(title)} definition"}]}
    end
  end

  defp enforcement_schema(_schema_atom, document), do: {:ok, document}

  defp ensure_object_payload(payload) when is_map(payload), do: :ok
  defp ensure_object_payload(_payload), do: {:error, [%{path: [], message: "must be an object"}]}

  defp required_errors(schema, payload) do
    schema
    |> Map.get("required", [])
    |> Enum.flat_map(fn key ->
      if has_payload_key?(payload, key) do
        []
      else
        [%{path: [key], message: "is required"}]
      end
    end)
  end

  defp type_errors(schema, payload) do
    schema
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {key, property_schema} ->
      case fetch_payload_value(payload, key) do
        {:ok, value} ->
          case Map.get(resolve_ref(property_schema, schema), "type") do
            nil ->
              []

            type ->
              if matches_schema_type?(value, type) do
                []
              else
                [%{path: [key], message: "expected type #{render_type(type)}"}]
              end
          end

        :error ->
          []
      end
    end)
  end

  # br's real schemas express most scalar fields as `{"$ref": "#/$defs/Priority"}`;
  # without resolving it the field's `type` is invisible and never checked.
  defp resolve_ref(%{"$ref" => "#/$defs/" <> name}, root) do
    case get_in(root, ["$defs", name]) do
      %{} = definition -> definition
      _ -> %{}
    end
  end

  defp resolve_ref(property_schema, _root), do: property_schema

  defp matches_schema_type?(value, types) when is_list(types) do
    Enum.any?(types, &matches_schema_type?(value, &1))
  end

  defp matches_schema_type?(value, "string"), do: is_binary(value)
  defp matches_schema_type?(value, "integer"), do: is_integer(value)
  defp matches_schema_type?(value, "number"), do: is_integer(value) or is_float(value)
  defp matches_schema_type?(value, "boolean"), do: is_boolean(value)
  defp matches_schema_type?(value, "array"), do: is_list(value)
  defp matches_schema_type?(value, "list"), do: is_list(value)
  defp matches_schema_type?(value, "object"), do: is_map(value)
  defp matches_schema_type?(value, "map"), do: is_map(value)
  defp matches_schema_type?(value, "null"), do: is_nil(value)
  defp matches_schema_type?(_value, _type), do: true

  defp render_type(types) when is_list(types), do: Enum.join(types, " | ")
  defp render_type(type), do: to_string(type)

  defp has_payload_key?(payload, key) do
    match?({:ok, _value}, fetch_payload_value(payload, key))
  end

  defp fetch_payload_value(payload, key) when is_map(payload) do
    key = normalize_key(key)

    Enum.find_value(payload, :error, fn {payload_key, value} ->
      if normalize_key(payload_key) == key do
        {:ok, value}
      else
        false
      end
    end)
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp detect_contract_version(schemas) do
    [:commands, :ready_issue, :issue_details, :error]
    |> Enum.find_value(fn schema_atom ->
      schemas
      |> Map.get(schema_atom, %{})
      |> extract_contract_version()
    end)
  end

  defp extract_contract_version(schema) when is_map(schema) do
    Enum.find_value(
      [
        ["contract_version"],
        ["contractVersion"],
        ["metadata", "contract_version"],
        ["metadata", "contractVersion"],
        ["contract", "version"],
        ["x-contract-version"]
      ],
      &get_in(schema, &1)
    )
  end

  defp extract_contract_version(_schema), do: nil

  defp emit_refresh_telemetry(%State{} = state) do
    TaskProviderTelemetry.emit(@refresh_event, %{count: 1}, %{
      schema_count: map_size(state.schemas),
      contract_version: state.version,
      refreshed_at: state.last_refresh
    })
  end

  defp maybe_emit_version_change(previous_version, current_version)
       when is_binary(previous_version) and is_binary(current_version) and
              previous_version != current_version do
    TaskProviderTelemetry.emit(@version_changed_event, %{count: 1}, %{
      previous_version: previous_version,
      current_version: current_version
    })
  end

  defp maybe_emit_version_change(_previous_version, _current_version), do: :ok

  defp schedule_refresh(refresh_interval_ms)
       when is_integer(refresh_interval_ms) and refresh_interval_ms > 0 do
    Process.send_after(self(), :refresh, refresh_interval_ms)
  end
end
