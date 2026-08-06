defmodule ForemanServer.TaskProviders.BeadsAdapter do
  @moduledoc "Production TaskProvider implementation backed by the `br` CLI. Unimplemented callbacks (list_ready, get, claim, complete, fail, reopen, set_priority, add_dependency) return {:error, :not_implemented} until TRD-011..TRD-018 fill them in."

  @behaviour ForemanServer.TaskProvider

  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap
  alias ForemanServer.TaskProviders.BeadsAdapter.CodeMap.ProviderErrorInput
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
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

    case @runner.cmd(request, project_config, timeout_ms: timeout_ms) do
      {:ok, _response} ->
        :telemetry.execute(
          [:foreman_server, :task_provider, :beads_adapter, :preflight, :ok],
          %{system_time: System.system_time()},
          %{database_path: database_path}
        )

        :ok

      {:error, %{stdout: stdout, stderr: stderr} = result} ->
        provider_error = build_preflight_error(stdout, stderr, result)

        :telemetry.execute(
          [:foreman_server, :task_provider, :beads_adapter, :preflight, :error],
          %{system_time: System.system_time()},
          %{database_path: database_path, error: provider_error}
        )

        {:error, provider_error}
    end
  end

  @impl true
  def list_ready(_actor, _opts), do: {:error, :not_implemented}

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
  def set_priority(_id, _priority, _opts), do: {:error, :not_implemented}

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
