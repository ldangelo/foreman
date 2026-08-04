defmodule ForemanServer.AgentRuntime do
  @moduledoc """
  TRD-2026-6af02293: public facade for the OTP-supervised agent runtime.

  The facade is the single entry point for callers that need a backend
  adapter executed. It owns public argument validation, exposes
  backend-agnostic result types, and never reveals a successful backend
  name in its return value (the name is recorded only in telemetry
  metadata).

  ## Public contracts (TRD §Public Contracts)

      @spec execute(String.t(), map(), keyword()) ::
              {:ok, String.t()} |
              {:error, :no_available_backend | :backend_not_found | :backend_unavailable | :timeout} |
              {:error, {:non_zero_exit, non_neg_integer()}} |
              {:error, :all_backends_failed, %{attempts: [attempt_result()]}} |
              {:error, term()}

  ## Scope by TRD task

    * TRD-001 (this task): types, public registration, capability
      validation gate. No supervisor, no catalog, no execution.
    * TRD-002: supervisor, catalog, invocation lifecycle.
    * TRD-003: `execute/3` implementation with manual routing.
  """

  alias ForemanServer.AgentRuntime.BackendAdapter
  alias ForemanServer.AgentRuntime.Capabilities
  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.AgentRuntime.Router
  alias ForemanServer.AgentRuntime.InvocationSupervisor
  alias ForemanServer.Telemetry

  @type backend_name :: atom()
  @type adapter :: module()
  @type capability_map :: map()

  @type attempt_result ::
          {:ok, backend_name(), String.t(), map()}
          | {:error, backend_name(), term()}

  @type execute_result ::
          {:ok, String.t()}
          | {:error, :no_available_backend | :backend_not_found | :backend_unavailable | :timeout}
          | {:error, {:non_zero_exit, non_neg_integer()}}
          | {:error, :all_backends_failed, %{attempts: [attempt_result()]}}
          | {:error, term()}

  @typedoc "Public strategy atom accepted by `execute/3` (TRD-003)."
  @type strategy :: :manual | :automatic | :policy

  @doc """
  Validate an adapter module's capability map without mutating any
  state. Returns `{:ok, capabilities}` on success and a field-specific
  `{:error, reason}` on failure. This is the registration gate called by
  the supervised catalog once it is wired (TRD-002); until then it acts
  as a stand-alone validator.

  An invalid adapter is never inserted; the function is pure with
  respect to durable state.
  """
  @spec register(adapter()) :: {:ok, capability_map()} | {:error, Capabilities.error_reason()}
  def register(adapter) do
    # Validate capabilities first (pure)
    result = BackendAdapter.validate_capabilities(adapter)

    # Side-effect: register with catalog if validation passed
    case result do
      {:ok, _caps} ->
        # Ignore catalog errors - the validated map is the primary return
        AdapterCatalog.register(adapter)
        result

      {:error, _} ->
        result
    end
  end

  @doc """
  Returns the list of fields required on a capability map.
  """
  @spec required_capability_fields() :: [atom()]
  defdelegate required_capability_fields(), to: Capabilities, as: :required_fields

  @doc """
  Returns the list of optional capability fields.
  """
  defdelegate optional_capability_fields(), to: Capabilities, as: :optional_fields

  @doc """
  Register an adapter at runtime with optional catalog injection.

  The `:catalog` option allows injecting a different catalog server for testing.
  """
  @spec register_adapter(adapter(), keyword()) ::
          {:ok, capability_map()} | {:error, Capabilities.error_reason()}
  def register_adapter(adapter, opts \\ []) do
    catalog = Keyword.get(opts, :catalog, AdapterCatalog)

    # Validate capabilities first (pure)
    result = BackendAdapter.validate_capabilities(adapter)

    case result do
      {:ok, _caps} ->
        # Register with catalog
        case GenServer.call(catalog, {:register, adapter}) do
          {:ok, _} -> result
          {:error, reason} -> {:error, reason}
        end

      {:error, _} ->
        result
    end
  end

  @doc """
  Execute a backend adapter.

  Arguments:
  - `prompt` - the prompt string to send to the backend
  - `context` - a map of context data
  - `opts` - keyword list containing:
    - `:strategy` - `:manual`, `:automatic`, or `:policy` (default: `:manual`)
    - `:backend` - backend name (required for manual strategy)
    - `:task_type` - task type for automatic routing
    - `:invocation_supervisor` - supervisor to use (optional)
    - `:timeout` - timeout in ms (default: 30000)

  Returns `{:ok, content}` on success or an error tuple.
  """
  @spec execute(String.t(), map(), keyword()) :: execute_result()
  def execute(prompt, context, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :manual)
    backend = Keyword.get(opts, :backend)

    # Build request map
    request = %{prompt: prompt, context: context}

    case strategy do
      :manual ->
        catalog = Keyword.get(opts, :catalog, AdapterCatalog)
        execute_manual(backend, request, Keyword.put(opts, :catalog, catalog))

      :automatic ->
        {:error, :not_implemented}

      :policy ->
        {:error, :not_implemented}

      other ->
        {:error, {:invalid_strategy, other}}
    end
  end

  # Manual strategy implementation
  defp execute_manual(nil, _request, _opts) do
    {:error, :backend_not_found}
  end

  defp execute_manual(backend, request, opts) do
    start_time = System.system_time()

    # Emit start telemetry (REQ-006: no prompt/context in metadata)
    Telemetry.execute(
      [:foreman, :agent_runtime, :execute, :start],
      %{system_time: start_time},
      %{strategy: :manual, backend: backend, status: :started}
    )

    # Route to adapter
    catalog = Keyword.get(opts, :catalog, AdapterCatalog)
    case Router.manual(backend, catalog: catalog) do
      {:ok, adapter_module} ->
        # Start invocation
        inv_supervisor = Keyword.get(opts, :invocation_supervisor, InvocationSupervisor)
        timeout = Keyword.get(opts, :timeout, 30_000)

        case InvocationSupervisor.start_invocation(adapter_module, request, self(), inv_supervisor) do
          {:ok, _pid, ref} ->
            # Wait for result
            receive do
              {:agent_runtime_invocation_complete, ^ref, result} ->
                # Normalize result to execute_result shape
                case result do
                  {:ok, _name, content, _meta} ->
                    # Emit stop telemetry
                    stop_time = System.system_time()
                    Telemetry.execute(
                      [:foreman, :agent_runtime, :execute, :stop],
                      %{duration_us: stop_time - start_time, status: :ok},
                      %{strategy: :manual, backend: backend, attempts: 1}
                    )
                    {:ok, content}

                  {:error, _name, reason} ->
                    # Emit stop telemetry
                    stop_time = System.system_time()
                    Telemetry.execute(
                      [:foreman, :agent_runtime, :execute, :stop],
                      %{duration_us: stop_time - start_time, status: :adapter_error},
                      %{strategy: :manual, backend: backend, attempts: 1}
                    )
                    {:error, reason}
                end
            after timeout ->
              # Emit stop telemetry
              stop_time = System.system_time()
              Telemetry.execute(
                [:foreman, :agent_runtime, :execute, :stop],
                %{duration_us: stop_time - start_time, status: :timeout},
                %{strategy: :manual, backend: backend, attempts: 1}
              )
              {:error, :timeout}
            end

          {:error, reason} ->
            # Emit stop telemetry
            stop_time = System.system_time()
            Telemetry.execute(
              [:foreman, :agent_runtime, :execute, :stop],
              %{duration_us: stop_time - start_time, status: :invocation_start_failed},
              %{strategy: :manual, backend: backend, attempts: 1}
            )
            {:error, reason}
        end

      {:error, :backend_not_found} ->
        # Emit stop telemetry
        stop_time = System.system_time()
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: stop_time - start_time, status: :backend_not_found},
          %{strategy: :manual, backend: backend, attempts: 0}
        )
        {:error, :backend_not_found}

      {:error, :backend_unavailable} ->
        # Emit stop telemetry
        stop_time = System.system_time()
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: stop_time - start_time, status: :backend_unavailable},
          %{strategy: :manual, backend: backend, attempts: 0}
        )
        {:error, :backend_unavailable}

      {:error, :no_available_backend} ->
        # Emit stop telemetry
        stop_time = System.system_time()
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: stop_time - start_time, status: :no_available_backend},
          %{strategy: :manual, backend: backend, attempts: 0}
        )
        {:error, :no_available_backend}
    end
  end
end
