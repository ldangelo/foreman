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
  alias ForemanServer.Agents.OtelSpanEmitter
  alias ForemanServer.Agents.LlmErrorHandler
  alias ForemanServer.Agents.LangfuseTracer

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
  @type strategy :: :manual | :automatic | :policy | :react | :cot

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
    - `:env` - adapter-private trusted env map (`BackendAdapter.env_map()`)
      forwarded to `adapter.execute/2` via the `:env` option. The env map is
      NEVER included in telemetry metadata, never logged, and never copied
      into completion fields. It is consumed only by the adapter at
      `Port.open` time.
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
    env = Keyword.get(opts, :env, %{})
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
          fail_on_unavailable,
          env
        )

      :automatic ->
        execute_automatic(
          task_type,
          request,
          catalog,
          inv_supervisor,
          policy,
          fail_on_unavailable,
          env
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
          fail_on_unavailable,
          env
        )

      :react ->
        model = Keyword.get(opts, :model, :fast)

        execute_react(
          prompt,
          request,
          model,
          task_type,
          policy,
          env
        )

      :cot ->
        model = Keyword.get(opts, :model, :fast)

        execute_cot(
          prompt,
          request,
          model,
          task_type,
          policy,
          env
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
         fail_on_unavailable,
         env
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
               inv_supervisor,
               env
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
  defp execute_automatic(
         task_type,
         request,
         catalog,
         inv_supervisor,
         policy,
         fail_on_unavailable,
         env
       ) do
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
               inv_supervisor,
               env
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
               inv_supervisor,
               env
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
               inv_supervisor,
               env
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
         fail_on_unavailable,
         env
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

        run_policy_invocation(
          candidates,
          policy,
          request,
          inv_supervisor,
          start_time,
          backend,
          task_type,
          env
        )

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

        run_policy_invocation(
          [],
          policy,
          request,
          inv_supervisor,
          start_time,
          nil,
          task_type,
          env
        )

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

  # ReAct strategy: delegate to JidoAiRunner with Jido.AI.Reasoning.ReAct,
  # which uses req_llm for LLM calls.  The runner is wrapped so exactly
  # one telemetry completion event fires per execute/3 call.  Each
  # successful branch emits a Langfuse trace (REQ-020) so the routing
  # decision (routed_to, routing_reason, capability) lands in the live
  # trace — without this call site the LangfuseTracer helper exists but
  # nothing ever invokes it.
  defp execute_react(prompt, _request, model, task_type, policy, _env) do
    start_time = System.system_time()
    monotonic_start = System.monotonic_time(:microsecond)
    timeout_ms = Map.get(policy, :timeout_ms, 60_000)

    try do
      Telemetry.execute(
        [:foreman, :agent_runtime, :execute, :start],
        %{system_time: start_time, status: :started},
        %{strategy: :react, backend: :jido_ai_runner}
      )

      case ForemanServer.Agents.JidoAiRunner.run(:react, prompt,
             model: model,
             max_tokens: 4096,
             timeout_ms: timeout_ms
           ) do
        {:ok, %{output: output} = result} when is_binary(output) ->
          stop_time = System.system_time()
          usage = Map.get(result, :usage, %{})
          token_count = Map.get(usage, :total_tokens, 0)
          _ = OtelSpanEmitter.emit_llm_span(model, token_count, 0.0, "auto")
          _ = emit_langfuse_trace(prompt, output, model, monotonic_start, task_type, token_count)

          Telemetry.execute(
            [:foreman, :agent_runtime, :execute, :stop],
            %{duration_us: stop_time - start_time, status: :ok, attempts: 1},
            %{strategy: :react, backend: :jido_ai_runner}
          )

          emit_early_exit_completion(monotonic_start, :ok, task_type)
          {:ok, output}

        {:ok, %{output: output} = result} ->
          stop_time = System.system_time()
          usage = Map.get(result, :usage, %{})
          token_count = Map.get(usage, :total_tokens, 0)
          _ = OtelSpanEmitter.emit_llm_span(model, token_count, 0.0, "auto")
          _ = emit_langfuse_trace(prompt, output, model, monotonic_start, task_type, token_count)

          Telemetry.execute(
            [:foreman, :agent_runtime, :execute, :stop],
            %{duration_us: stop_time - start_time, status: :ok, attempts: 1},
            %{strategy: :react, backend: :jido_ai_runner}
          )

          emit_early_exit_completion(monotonic_start, :ok, task_type)
          {:ok, inspect(output)}

        {:error, _reason} = error ->
          stop_time = System.system_time()

          Telemetry.execute(
            [:foreman, :agent_runtime, :execute, :stop],
            %{duration_us: stop_time - start_time, status: :adapter_error, attempts: 1},
            %{strategy: :react, backend: :jido_ai_runner}
          )

          emit_early_exit_completion(monotonic_start, :adapter_error, task_type)

          # REQ-008 AC-008-2: classify LLM errors and return as agent directives
          # so the agent can retry or escalate rather than treating them as fatal.
          error_kind =
            case _reason do
              :failed -> :llm_failed
              {:run_error, _} -> :llm_run_error
              _ -> :llm_error
            end

          LlmErrorHandler.classify_and_directive(error_kind, %{source: :jido_ai_runner})
      end
    rescue
      e ->
        stop_time = System.system_time()

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: stop_time - start_time, status: :exception, attempts: 1},
          %{strategy: :react, backend: :jido_ai_runner}
        )

        emit_early_exit_completion(monotonic_start, :exception, task_type)
        {:error, {:exception, Exception.message(e)}}
    end
  end

  # Chain-of-Thought strategy: same pattern as execute_react/6.
  defp execute_cot(prompt, _request, model, task_type, policy, _env) do
    start_time = System.system_time()
    monotonic_start = System.monotonic_time(:microsecond)
    timeout_ms = Map.get(policy, :timeout_ms, 60_000)

    try do
      Telemetry.execute(
        [:foreman, :agent_runtime, :execute, :start],
        %{system_time: start_time, status: :started},
        %{strategy: :cot, backend: :jido_ai_runner}
      )

      case ForemanServer.Agents.JidoAiRunner.run(:cot, prompt,
             model: model,
             max_tokens: 4096,
             timeout_ms: timeout_ms
           ) do
        {:ok, %{output: output} = result} when is_binary(output) ->
          stop_time = System.system_time()
          usage = Map.get(result, :usage, %{})
          token_count = Map.get(usage, :total_tokens, 0)
          _ = OtelSpanEmitter.emit_llm_span(model, token_count, 0.0, "auto")
          _ = emit_langfuse_trace(prompt, output, model, monotonic_start, task_type, token_count)

          Telemetry.execute(
            [:foreman, :agent_runtime, :execute, :stop],
            %{duration_us: stop_time - start_time, status: :ok, attempts: 1},
            %{strategy: :cot, backend: :jido_ai_runner}
          )

          emit_early_exit_completion(monotonic_start, :ok, task_type)
          {:ok, output}

        {:ok, %{output: output} = result} ->
          stop_time = System.system_time()
          usage = Map.get(result, :usage, %{})
          token_count = Map.get(usage, :total_tokens, 0)
          _ = OtelSpanEmitter.emit_llm_span(model, token_count, 0.0, "auto")
          _ = emit_langfuse_trace(prompt, output, model, monotonic_start, task_type, token_count)

          Telemetry.execute(
            [:foreman, :agent_runtime, :execute, :stop],
            %{duration_us: stop_time - start_time, status: :ok, attempts: 1},
            %{strategy: :cot, backend: :jido_ai_runner}
          )

          emit_early_exit_completion(monotonic_start, :ok, task_type)
          {:ok, inspect(output)}

        {:error, _reason} = error ->
          stop_time = System.system_time()

          Telemetry.execute(
            [:foreman, :agent_runtime, :execute, :stop],
            %{duration_us: stop_time - start_time, status: :adapter_error, attempts: 1},
            %{strategy: :cot, backend: :jido_ai_runner}
          )

          emit_early_exit_completion(monotonic_start, :adapter_error, task_type)

          # REQ-008 AC-008-2: classify LLM errors and return as agent directives
          # so the agent can retry or escalate rather than treating them as fatal.
          error_kind =
            case _reason do
              :failed -> :llm_failed
              {:run_error, _} -> :llm_run_error
              _ -> :llm_error
            end

          LlmErrorHandler.classify_and_directive(error_kind, %{source: :jido_ai_runner})
      end
    rescue
      e ->
        stop_time = System.system_time()

        Telemetry.execute(
          [:foreman, :agent_runtime, :execute, :stop],
          %{duration_us: stop_time - start_time, status: :exception, attempts: 1},
          %{strategy: :cot, backend: :jido_ai_runner}
        )

        emit_early_exit_completion(monotonic_start, :exception, task_type)
        {:error, {:exception, Exception.message(e)}}
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
         task_type,
         env
       ) do
    monotonic_start = System.monotonic_time(:microsecond)

    case InvocationSupervisor.start_invocation(
           candidates,
           policy,
           request,
           self(),
           task_type,
           inv_supervisor,
           env
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

  # REQ-020 / LGL-T004 — wire LangfuseTracer.emit_trace/6 into every
  # successful LLM call so routed_to / routing_reason / capability land
  # in the live trace. cost_usd is 0.0 here because the JidoAiRunner
  # abstraction doesn't surface pricing; once req_llm's response carries
  # cost, swap the literal for the actual value. Latency is measured
  # from `monotonic_start` so the trace mirrors the Otel span duration.
  defp emit_langfuse_trace(prompt, response, model, monotonic_start, task_type, token_count) do
    duration_ms = div(System.monotonic_time(:microsecond) - monotonic_start, 1_000)
    capability = capability_for_task_type(task_type)

    LangfuseTracer.emit_trace(prompt, response, model, 0.0, duration_ms,
      routed_to: model,
      routing_reason: routing_reason_for(capability),
      capability: capability,
      token_count: token_count
    )
  end

  # Map a Foreman task_type to a LiteLLM routing capability. Anything
  # unknown falls through to :chat.
  defp capability_for_task_type(task_type) when is_atom(task_type) do
    case task_type do
      :code -> :code_generation
      :code_generation -> :code_generation
      :embedding -> :embedding
      :chat -> :chat
      :reasoning -> :chat
      _ -> :chat
    end
  end

  defp capability_for_task_type(_), do: :chat

  defp routing_reason_for(:code_generation), do: "auto-routing:code"
  defp routing_reason_for(:embedding), do: "auto-routing:embedding"
  defp routing_reason_for(:chat), do: "auto-routing:chat"
  defp routing_reason_for(_), do: "auto-routing"

  # Test-only export. Avoid calling from production code.
  @doc false
  def __emit_langfuse_trace_for_test__(prompt, response, model, monotonic_start, task_type, token_count) do
    emit_langfuse_trace(prompt, response, model, monotonic_start, task_type, token_count)
  end
end
