defmodule ForemanServer.TaskProvider.Telemetry do
  @moduledoc false

  @type event_path :: [atom()]
  @type taxonomy_entry :: %{
          metadata_keys: [atom()],
          scrub_required?: boolean(),
          description: String.t()
        }

  @documented_taxonomy %{
    [:foreman_server, :task_provider, :registry, :restarted] => %{
      metadata_keys: [:restart_count, :providers, :registry],
      scrub_required?: false,
      description: "Registry restarted and rebuilt its routing snapshot."
    },
    [:foreman_server, :task_provider, :beads, :capabilities, :refreshed] => %{
      metadata_keys: [:schema_count, :contract_version, :refreshed_at],
      scrub_required?: false,
      description: "Schema cache refreshed and observed the active contract version."
    },
    [:foreman_server, :task_provider, :beads, :temp_file, :leaked] => %{
      metadata_keys: [:kind],
      scrub_required?: false,
      description: "SystemBrRunner detected and cleaned a leaked temporary file."
    },
    [:foreman_server, :task_provider, :beads_adapter, :claim, :success] => %{
      metadata_keys: [:argv],
      scrub_required?: true,
      description: "BeadsAdapter claim succeeded."
    },
    [:foreman_server, :task_provider, :claim, :lost] => %{
      metadata_keys: [],
      scrub_required?: false,
      description:
        "RunExecutor retried list_ready/2 and the target claim was no longer recoverable."
    },
    [:foreman_server, :task_provider, :beads_adapter, :complete, :success] => %{
      metadata_keys: [:argv],
      scrub_required?: true,
      description: "BeadsAdapter complete succeeded."
    },
    [:foreman_server, :task_provider, :beads_adapter, :fail, :success] => %{
      metadata_keys: [:argv],
      scrub_required?: true,
      description: "BeadsAdapter fail/open transition succeeded."
    },
    [:foreman_server, :task_provider, :transition_comment, :rejected] => %{
      metadata_keys: [:argv, :raw_code, :task_id],
      scrub_required?: true,
      description:
        "A fail/open transition was rejected and the unmapped br error code was surfaced."
    },
    [:foreman_server, :task_provider, :beads_adapter, :reopen, :success] => %{
      metadata_keys: [:argv],
      scrub_required?: true,
      description: "BeadsAdapter reopen succeeded for BootReconciliation."
    },
    [:foreman_server, :task_provider, :reconcile, :reopened] => %{
      metadata_keys: [:issue_id, :run_id],
      scrub_required?: false,
      description: "BootReconciliation reopened an orphaned in-progress claim."
    },
    [:foreman_server, :task_provider, :reconcile, :already_closed] => %{
      metadata_keys: [:issue_id, :run_id],
      scrub_required?: false,
      description: "BootReconciliation found an in-progress run whose issue was already closed."
    },
    [:foreman_server, :task_provider, :reconcile, :healthy] => %{
      metadata_keys: [:issue_id, :run_id],
      scrub_required?: false,
      description: "BootReconciliation confirmed an in-progress claim already matched a live run."
    },
    [:foreman_server, :task_provider, :beads_adapter, :doctor, :probe] => %{
      metadata_keys: [:argv],
      scrub_required?: true,
      description: "Doctor probed the BeadsAdapter through the provider contract."
    }
  }

  @implementation_taxonomy %{
    [:foreman_server, :task_provider, :registry, :route, :ok] => %{
      metadata_keys: [:transition, :routing_key, :provider],
      scrub_required?: false,
      description: "Registry.route/2 resolved a provider for the requested transition."
    },
    [:foreman_server, :task_provider, :registry, :route, :error] => %{
      metadata_keys: [:transition, :routing_key, :reason],
      scrub_required?: false,
      description: "Registry.route/2 failed to resolve a provider for the requested transition."
    },
    [:foreman_server, :task_provider, :registry, :register_for_project, :ok] => %{
      metadata_keys: [:project_id, :provider],
      scrub_required?: false,
      description: "Registry registered a per-project task provider."
    },
    [:foreman_server, :task_provider, :registry, :register_for_project, :error] => %{
      metadata_keys: [:project_id, :provider, :reason],
      scrub_required?: false,
      description: "Registry rejected a per-project task provider registration."
    },
    [:foreman_server, :task_provider, :registry, :unregister_for_project] => %{
      metadata_keys: [:project_id, :reason],
      scrub_required?: false,
      description: "Registry removed a per-project task provider registration."
    },
    [:foreman_server, :task_provider, :beads, :contract, :version_changed] => %{
      metadata_keys: [:previous_version, :current_version],
      scrub_required?: false,
      description: "JsonSchemaCache observed a contract-version change across refreshes."
    },
    [:foreman_server, :task_provider, :beads_adapter, :preflight, :start] => %{
      metadata_keys: [:argv, :timeout_ms],
      scrub_required?: true,
      description: "BeadsAdapter preflight started a br where probe."
    },
    [:foreman_server, :task_provider, :beads_adapter, :preflight, :ok] => %{
      metadata_keys: [:argv],
      scrub_required?: true,
      description: "BeadsAdapter preflight confirmed the configured database path."
    },
    [:foreman_server, :task_provider, :beads_adapter, :preflight, :error] => %{
      metadata_keys: [:argv, :error],
      scrub_required?: true,
      description: "BeadsAdapter preflight returned a ProviderError."
    },
    [:foreman_server, :task_provider, :concurrency_limiter, :acquire] => %{
      metadata_keys: [:project_id, :source, :in_flight],
      scrub_required?: false,
      description: "ConcurrencyLimiter granted a project-scoped slot."
    },
    [:foreman_server, :task_provider, :concurrency_limiter, :release] => %{
      metadata_keys: [:project_id, :granted_waiter?, :in_flight],
      scrub_required?: false,
      description: "ConcurrencyLimiter released a project-scoped slot."
    },
    [:foreman_server, :task_provider, :concurrency_limiter, :timeout] => %{
      metadata_keys: [:project_id],
      scrub_required?: false,
      description: "ConcurrencyLimiter timed out a queued caller without consuming a slot."
    }
  }

  @taxonomy Map.merge(@documented_taxonomy, @implementation_taxonomy)
  @sentinel_keys [
    :database_path,
    :claim_token,
    :completion_token,
    :failure_token,
    :transition_comment
  ]
  @database_path_flag "--db"
  @transition_comment_flag "--transition-comment"

  @spec taxonomy() :: %{event_path() => taxonomy_entry()}
  def taxonomy, do: @taxonomy

  @spec scrub_argv(argv :: [String.t()]) :: [String.t()]
  def scrub_argv(argv) when is_list(argv) do
    argv
    |> Enum.map_reduce(nil, &scrub_argv_entry/2)
    |> elem(0)
  end

  @spec emit(event_path(), map(), map()) :: :ok
  def emit(event, measurements, metadata \\ %{})
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    :telemetry.execute(event, measurements, scrub_metadata(metadata))
  end

  defp scrub_metadata(metadata) do
    case Map.fetch(metadata, :argv) do
      {:ok, argv} when is_list(argv) -> Map.put(metadata, :argv, scrub_argv(argv))
      _ -> metadata
    end
  end

  defp scrub_argv_entry({key, value}, pending_flag) when key in @sentinel_keys do
    {{key, redact_value(key, value)}, pending_flag}
  end

  defp scrub_argv_entry(value, :database_path) when is_binary(value) do
    {redact_value(:database_path, value), nil}
  end

  defp scrub_argv_entry(value, :transition_comment) when is_binary(value) do
    {redact_value(:transition_comment, value), nil}
  end

  defp scrub_argv_entry(value, _pending_flag) when value == @database_path_flag do
    {value, :database_path}
  end

  defp scrub_argv_entry(value, _pending_flag) when value == @transition_comment_flag do
    {value, :transition_comment}
  end

  defp scrub_argv_entry(value, _pending_flag), do: {value, nil}

  defp redact_value(:database_path, value) when is_binary(value) do
    "/abs/<redacted:#{String.length(value)}>"
  end

  defp redact_value(key, value) when key in [:claim_token, :completion_token, :failure_token] do
    if is_binary(value), do: "<redacted:8>", else: value
  end

  defp redact_value(:transition_comment, value) when is_binary(value) and byte_size(value) > 64 do
    "<redacted:64>"
  end

  defp redact_value(_key, value), do: value
end
