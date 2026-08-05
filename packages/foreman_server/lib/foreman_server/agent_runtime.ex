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
    * TRD-008: fallback orchestration, attempt history, bounded retries.
  """

  alias ForemanServer.AgentRuntime.BackendAdapter
  alias ForemanServer.AgentRuntime.Capabilities
  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.AgentRuntime.Router
  alias ForemanServer.AgentRuntime.InvocationSupervisor
  alias ForemanServer.Telemetry
  alias ForemanServer.AgentRuntime.FailurePolicy

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
  Resolves the failure policy for a given task type and call options.

  Delegates to `FailurePolicy.resolve/2`. See that module for full documentation.
  """
  @spec failure_policy(atom() | nil, keyword() | map()) :: map()
  defdelegate failure_policy(task_type, opts \\ []), to: FailurePolicy, as: :resolve

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
    - `:task_type` - task type for automatic or policy routing
    - `:invocation_supervisor` - supervisor to use (optional)
    - `:timeout` - timeout in ms (default: 30000) - passed to FailurePolicy
    - `:fallback` - whether to try fallback backends on failure
    - `:max_attempts` - maximum number of attempts
    - `:fail_on_unavailable` - return immediately if no backends available (default: true)

  Returns `{:ok, content}` on success or an error tuple.
  """
  @spec execute(String.t(), map(), keyword()) :: execute_result()
  def execute(prompt, context, opts \\ []) do
    strategy = Keyword.get(opts, :strategy, :manual)
    backend = Keyword.get(opts, :backend)

    # Build request map
    request = %{prompt: prompt, context: context}

    # Get common options
    catalog = Keyword.get(opts, :catalog, AdapterCatalog)
    inv_supervisor = Keyword.get(opts, :invocation_supervisor, InvocationSupervisor)
    task_type = Keyword.get(opts, :task_type)
    fail_on_unavailable = Keyword.get(opts, :fail_on_unavailable, true)

    # Resolve failure policy
    policy_opts = Keyword.take(opts, [:timeout_ms, :fallback, :max_attempts])
    policy = FailurePolicy.resolve(task_type, policy_opts)

    case strategy do
      :manual ->
        execute_manual(
          backend,
          task_type,
          request,
          catalog,
          inv_supervisor,
          policy,
          fail_on_unavailable
        )

      :automatic ->
        execute_automatic(
          task_type,
          request,
          catalog,
          inv_supervisor,
          policy,
          fail_on_unavailable
        )

      :policy ->
        policy_module = Keyword.get(opts, :policy_module)

        execute_policy(
          policy_module,
          task_type,
          request,
          catalog,
          inv_supervisor,
          policy,
          fail_on_unavailable
        )

      other ->
        # Capture monotonic_start at the very top so the completion event can
        # be emitted before the facade returns. This branch never reaches an
        # Invocation, so the helper is the only path for the contract's
        # "exactly one completion event per execute/3 call."
        monotonic_start = System.monotonic_time(:microsecond)
        emit_early_exit_completion(monotonic_start, :invalid_strategy, task_type)
        {:error, {:invalid_strategy, other}}
    end
  end

  # Manual strategy: single backend, build single-element candidates
  defp execute_manual(
         backend,
         task_type,
         request,
         catalog,
         inv_supervisor,
         policy,
         fail_on_unavailable
       ) do
    start_time = System.system_time()
    monotonic_start = System.monotonic_time(:microsecond)

    case Router.manual(backend, catalog: catalog) do
      {:ok, adapter_module} ->
        # Get backend name for telemetry
        backend_name = adapter_module.name()

        # Emit start telemetry with actual backend
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :manual, backend: backend_name}
        )

        # Build single-element candidates list with availability flag
        candidates = [{adapter_module, true}]

        # Start invocation
        case InvocationSupervisor.start_invocation(
               candidates,
               policy,
               request,
               self(),
               task_type,
               inv_supervisor
             ) do
          {:ok, _pid, ref} ->
            receive_result(ref, start_time, :manual, backend_name)
          {:error, reason} ->
            stop_time = System.system_time()

            Telemetry.execute(
              [:foreman, :agent_runtime, :execute, :stop],
              %{
                duration_us: stop_time - start_time,
                status: :invocation_start_failed,
                attempts: 1
              },
              %{strategy: :manual, backend: backend_name}
            )

            emit_early_exit_completion(monotonic_start, :invocation_start_failed, task_type)

            {:error, reason}
        end
      {:error, :backend_not_found} ->
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :manual, backend: nil}
        )

        stop_time = System.system_time()

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: stop_time - start_time, status: :backend_not_found, attempts: 0},
          %{strategy: :manual, backend: nil}
        )

        emit_early_exit_completion(monotonic_start, :backend_not_found, task_type)

        {:error, :backend_not_found}
      {:error, :backend_unavailable} ->
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :manual, backend: nil}
        )

        stop_time = System.system_time()

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: stop_time - start_time, status: :backend_unavailable, attempts: 0},
          %{strategy: :manual, backend: nil}
        )

        emit_early_exit_completion(monotonic_start, :backend_unavailable, task_type)

        {:error, :backend_unavailable}
      {:error, :no_available_backend} ->
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :manual, backend: nil}
        )

        stop_time = System.system_time()

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: stop_time - start_time, status: :no_available_backend, attempts: 0},
          %{strategy: :manual, backend: nil}
        )

        emit_early_exit_completion(monotonic_start, :no_available_backend, task_type)

        {:error, :no_available_backend}
    end
  end

  # Automatic strategy: use Router.automatic_candidates
  defp execute_automatic(task_type, request, catalog, inv_supervisor, policy, fail_on_unavailable) do
    start_time = System.system_time()
    monotonic_start = System.monotonic_time(:microsecond)

    case Router.automatic_candidates(request, catalog: catalog, task_type: task_type) do
      {:ok, candidates} when candidates != [] ->
        backend =
          case hd(candidates) do
            {adapter, _} -> adapter.name()
            _ -> nil
          end

        # Emit start telemetry with actual backend
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :automatic, backend: backend}
        )

        # Start invocation with candidates
        case InvocationSupervisor.start_invocation(
               candidates,
               policy,
               request,
               self(),
               task_type,
               inv_supervisor
             ) do
          {:ok, _pid, ref} ->
            receive_result(ref, start_time, :automatic, backend)

          {:error, reason} ->
            stop_time = System.system_time()

            Telemetry.execute(
              [:foreman, :agent_runtime, :execute, :stop],
              %{
                duration_us: stop_time - start_time,
                status: :invocation_start_failed,
                attempts: 1
              },
              %{strategy: :automatic, backend: backend}
            )

            emit_early_exit_completion(monotonic_start, :invocation_start_failed, task_type)

            {:error, reason}
        end
      {:ok, []} when fail_on_unavailable ->
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :automatic, backend: nil}
        )

        stop_time = System.system_time()

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: stop_time - start_time, status: :no_available_backend, attempts: 0},
          %{strategy: :automatic, backend: nil}
        )

        emit_early_exit_completion(monotonic_start, :no_available_backend, task_type)

        {:error, :no_available_backend}
      {:error, :no_available_backend} when fail_on_unavailable ->
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :automatic, backend: nil}
        )

        stop_time = System.system_time()

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: stop_time - start_time, status: :no_available_backend, attempts: 0},
          %{strategy: :automatic, backend: nil}
        )

        emit_early_exit_completion(monotonic_start, :no_available_backend, task_type)

        {:error, :no_available_backend}

      # When fail_on_unavailable is false, start Invocation with empty candidates
      {:ok, []} ->
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :automatic, backend: nil}
        )

        candidates = []

        case InvocationSupervisor.start_invocation(
               candidates,
               policy,
               request,
               self(),
               task_type,
               inv_supervisor
             ) do
          {:ok, _pid, ref} ->
            receive_result(ref, start_time, :automatic, nil)

          {:error, reason} ->
            stop_time = System.system_time()

            Telemetry.execute(
              [:foreman, :agent_runtime, :execute, :stop],
              %{
                duration_us: stop_time - start_time,
                status: :invocation_start_failed,
                attempts: 1
              },
              %{strategy: :automatic, backend: nil}
            )

            emit_early_exit_completion(monotonic_start, :invocation_start_failed, task_type)

            {:error, reason}
        end
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :automatic, backend: nil}
        )

        # Start Invocation with empty candidates when fail_on_unavailable is false
        candidates = []

        case InvocationSupervisor.start_invocation(
               candidates,
               policy,
               request,
               self(),
               task_type,
               inv_supervisor
             ) do
          {:ok, _pid, ref} ->
            receive_result(ref, start_time, :automatic, nil)

          {:error, reason} ->
            stop_time = System.system_time()

            Telemetry.execute(
              [:foreman, :agent_runtime, :execute, :stop],
              %{
                duration_us: stop_time - start_time,
                status: :invocation_start_failed,
                attempts: 1
              },
              %{strategy: :automatic, backend: nil}
            )

            emit_early_exit_completion(monotonic_start, :invocation_start_failed, task_type)

            {:error, reason}
        end
    end
  end

  # Policy strategy: use Router.policy/3.
  #
  # `fail_on_unavailable` is honored ONLY for `{:error, :no_available_backend}`.
  # When true, the facade short-circuits and returns immediately without
  # spawning an Invocation. When false (default), an Invocation is started
  # with an empty candidate list and returns the same result on its own.
  #
  # `{:error, :backend_not_found}` and `{:error, {:policy_module_raised, ...}}`
  # are real router errors and are propagated unchanged regardless of the opt.
  defp execute_policy(
        policy_module,
        task_type,
        request,
        catalog,
        inv_supervisor,
        policy,
        fail_on_unavailable
      ) do
    start_time = System.system_time()
    monotonic_start = System.monotonic_time(:microsecond)

    case Router.policy(request, [catalog: catalog, task_type: task_type], policy_module) do
      {:ok, candidates} ->
        backend =
          case hd(candidates) do
            {adapter, _} -> adapter.name()
            _ -> nil
          end

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :policy, backend: backend}
        )

        run_policy_invocation(candidates, policy, request, inv_supervisor, start_time, backend, task_type)
      {:error, :no_available_backend} when fail_on_unavailable ->
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :policy, backend: nil}
        )

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: 0, status: :no_available_backend, attempts: 0},
          %{strategy: :policy, backend: nil}
        )

        emit_early_exit_completion(monotonic_start, :no_available_backend, task_type)

        {:error, :no_available_backend}

      {:error, :no_available_backend} ->
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :policy, backend: nil}
        )

        run_policy_invocation([], policy, request, inv_supervisor, start_time, nil, task_type)

      {:error, :backend_not_found} ->
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :policy, backend: nil}
        )

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: 0, status: :backend_not_found, attempts: 0},
          %{strategy: :policy, backend: nil}
        )

        emit_early_exit_completion(monotonic_start, :backend_not_found, task_type)

        {:error, :backend_not_found}
      {:error, {:policy_module_raised, _kind, _reason} = raised} ->
        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :start],
          %{system_time: start_time, status: :started},
          %{strategy: :policy, backend: nil}
        )

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: 0, status: :policy_module_raised, attempts: 0},
          %{strategy: :policy, backend: nil}
        )

        emit_early_exit_completion(monotonic_start, :policy_module_raised, task_type)

        {:error, raised}
    end
  end

  # Spawn an Invocation for the policy strategy and bridge its result through
  # the facade's telemetry/receive plumbing. Used by both the `:ok` and the
  # no-opt `:no_available_backend` branches.
  defp run_policy_invocation(
         candidates,
         policy,
         request,
         inv_supervisor,
         start_time,
         backend,
         task_type
       ) do
    monotonic_start = System.monotonic_time(:microsecond)

    case InvocationSupervisor.start_invocation(
           candidates,
           policy,
           request,
           self(),
           task_type,
           inv_supervisor
         ) do
      {:ok, _pid, ref} ->
        receive_result(ref, start_time, :policy, backend)

      {:error, reason} ->
        stop_time = System.system_time()

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{
            duration_us: stop_time - start_time,
            status: :invocation_start_failed,
            attempts: 1
          },
          %{strategy: :policy, backend: backend}
        )

        emit_early_exit_completion(monotonic_start, :invocation_start_failed, task_type)

        {:error, reason}
    end
  end

  # Receive result from Invocation - no facade timeout, Invocation enforces its own
  defp receive_result(ref, start_time, strategy, backend) do
    receive do
      {:agent_runtime_invocation_complete, ^ref, result} ->
        case result do
          {:ok, content} ->
            stop_time = System.system_time()

            Telemetry.execute(
              [:foreman, :agent_runtime, :execute, :stop],
              %{duration_us: stop_time - start_time, status: :ok, attempts: 1},
              %{strategy: strategy, backend: backend}
            )

            {:ok, content}

          {:error, reason} ->
            stop_time = System.system_time()

            Telemetry.execute(
              [:foreman, :agent_runtime, :execute, :stop],
              %{duration_us: stop_time - start_time, status: :adapter_error, attempts: 1},
              %{strategy: strategy, backend: backend}
            )

            {:error, reason}

          {:error, :all_backends_failed, %{attempts: attempts}} ->
            stop_time = System.system_time()

            Telemetry.execute(
              [:foreman, :agent_runtime, :execute, :stop],
              %{
                duration_us: stop_time - start_time,
                status: :all_backends_failed,
                attempts: length(attempts)
              },
              %{strategy: strategy, backend: backend}
            )

            {:error, :all_backends_failed, %{attempts: attempts}}

          {:error, :no_available_backend} ->
            stop_time = System.system_time()

            Telemetry.execute(
              [:foreman, :agent_runtime, :execute, :stop],
              %{duration_us: stop_time - start_time, status: :no_available_backend, attempts: 0},
              %{strategy: strategy, backend: backend}
            )

            {:error, :no_available_backend}
        end
    end
  end
  # Emit the privacy-safe completion telemetry for an early-exit branch where
  # the Invocation process never ran. The contract requires exactly one
  # [:foreman, :agent_runtime, :invocation, :complete] event per
  # `agent_runtime.execute/3` call; this helper satisfies it for paths that
  # fail before spawn (router errors, fail-on-unavailable short-circuits,
  # invocation start failures).
  defp emit_early_exit_completion(start_time, status, task_type) do
    duration_us = System.monotonic_time(:microsecond) - start_time

    Telemetry.agent_runtime_execute(
      %{duration_us: duration_us, attempt_count: 0},
      %{
        status: status,
        task_type: task_type,
        attempted_backends: [],
        successful_backend: nil,
        final_backend: nil
      }
    )
  end
end
