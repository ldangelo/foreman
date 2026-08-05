defmodule ForemanServer.AgentRuntimeTRD008Test do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime
  alias ForemanServer.AgentRuntime.{AdapterCatalog, BackendAdapter, InvocationSupervisor}

  # Test adapters that send messages to test process to verify invocation
  defmodule PrimaryFailsAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :primary_fails
    @impl true
    def capabilities,
      do: %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat],
        cost_per_call: 0.001,
        typical_latency_ms: 100
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(request, _opts) do
      # Signal that we were called
      send(request.context.test_pid, {:adapter_called, :primary_fails})
      {:error, :primary_failed}
    end
  end

  defmodule FallbackSucceedsAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :fallback_succeeds
    @impl true
    def capabilities,
      do: %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat],
        cost_per_call: 0.002,
        typical_latency_ms: 200
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(request, _opts) do
      send(request.context.test_pid, {:adapter_called, :fallback_succeeds})
      {:ok, "fallback response", %{}}
    end
  end

  defmodule BothFailAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :both_fail
    @impl true
    def capabilities,
      do: %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat]
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(request, _opts) do
      send(request.context.test_pid, {:adapter_called, :both_fail})
      {:error, :both_failed}
    end
  end

  defmodule ThirdFailsAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :third_fails
    @impl true
    def capabilities,
      do: %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat],
        cost_per_call: 0.003,
        typical_latency_ms: 300
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(request, _opts) do
      send(request.context.test_pid, {:adapter_called, :third_fails})
      {:error, :third_failed}
    end
  end

  defmodule UnavailableAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :unavailable
    @impl true
    def capabilities,
      do: %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat]
      }

    @impl true
    def available?, do: false
    @impl true
    def execute(_request, _opts) do
      # Should never be called
      {:ok, "should not reach", %{}}
    end
  end

  defmodule PrimaryAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :primary
    @impl true
    def capabilities,
      do: %{
        type: :language_model,
        strengths: [:coding],
        weaknesses: [],
        supported_contexts: [:chat]
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(request, _opts) do
      send(request.context.test_pid, {:adapter_called, :primary})
      {:error, :primary_error}
    end
  end

  defp start_test_catalog(id) do
    unique = :erlang.unique_integer()
    name = :"AdapterCatalog.Test.#{id}.#{unique}"
    start_supervised!({AdapterCatalog, [name: name]}, id: {id, unique})
    name
  end

  defp start_inv_sup(id) do
    unique = :erlang.unique_integer()
    name = :"InvocationSupervisor.Test.#{id}.#{unique}"
    start_supervised!({InvocationSupervisor, [name: name]}, id: {id, unique})
    name
  end

  # AC 1: Fallback enabled + first available backend fails → attempt next ranked available backend
  describe "AC 1: Fallback enabled - attempts next available backend" do
    test "primary fails, fallback succeeds, returns fallback result with 2 attempts" do
      catalog = start_test_catalog(:ac1)
      sup_name = start_inv_sup(:ac1)

      # Register adapters (ordered by registration - primary first, fallback second)
      {:ok, _} = AdapterCatalog.register(PrimaryFailsAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(FallbackSucceedsAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fallback: true,
          max_attempts: 2
        )

      # Should return fallback success
      assert result == {:ok, "fallback response"}

      # Verify both were called (in order)
      assert_receive {:adapter_called, :primary_fails}
      assert_receive {:adapter_called, :fallback_succeeds}
    end
  end

  # AC 2: Fallback disabled + first available backend fails → NO other backend executes
  describe "AC 2: Fallback disabled - returns direct error" do
    test "primary fails, fallback NOT called, returns direct error" do
      catalog = start_test_catalog(:ac2)
      sup_name = start_inv_sup(:ac2)

      # Register both adapters
      {:ok, _} = AdapterCatalog.register(PrimaryFailsAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(FallbackSucceedsAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fallback: false,
          max_attempts: 1
        )

      # Should return direct error from primary
      assert result == {:error, :primary_failed}

      # Verify ONLY primary was called (fallback NOT called)
      assert_receive {:adapter_called, :primary_fails}
      refute_receive {:adapter_called, :fallback_succeeds}
    end
  end

  # AC 3: All attempted attempts fail → :all_backends_failed with attempts in execution order
  describe "AC 3: All backends fail - returns all_backends_failed" do
    test "both backends fail, returns error with attempts in order" do
      catalog = start_test_catalog(:ac3)
      sup_name = start_inv_sup(:ac3)

      # Register two adapters that both fail
      {:ok, _} = AdapterCatalog.register(PrimaryFailsAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(BothFailAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fallback: true,
          max_attempts: 2
        )

      # Should return :all_backends_failed with attempts in execution order
      assert {:error, :all_backends_failed, %{attempts: attempts}} = result

      # Should have 2 attempts in execution order
      assert length(attempts) == 2

      # First attempt should be primary_fails
      assert {:error, :primary_fails, :primary_failed} = hd(attempts)

      # Verify both were called in order
      assert_receive {:adapter_called, :primary_fails}
      assert_receive {:adapter_called, :both_fail}
    end
  end

  # AC 3a: Fallback enabled with one available candidate that fails → :all_backends_failed
  # (Not direct error — fallback enabled means the policy wanted to fall back; with
  # no more available candidates, the attempt set is exhausted.)
  describe "AC 3a: Fallback enabled - one available candidate fails" do
    test "fallback enabled with single available backend that fails returns :all_backends_failed" do
      catalog = start_test_catalog(:ac3a_single)
      sup_name = start_inv_sup(:ac3a_single)

      {:ok, _} = AdapterCatalog.register(PrimaryFailsAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fallback: true,
          max_attempts: 1
        )

      assert {:error, :all_backends_failed, %{attempts: attempts}} = result
      assert length(attempts) == 1
      assert {:error, :primary_fails, :primary_failed} = hd(attempts)
      assert_receive {:adapter_called, :primary_fails}
    end

    test "fallback enabled with mixed available/unavailable candidates returns :all_backends_failed" do
      catalog = start_test_catalog(:ac3a_mixed)
      sup_name = start_inv_sup(:ac3a_mixed)

      {:ok, _} = AdapterCatalog.register(PrimaryFailsAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(UnavailableAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fallback: true,
          max_attempts: 2
        )

      # Only one AVAILABLE candidate; the unavailable one is skipped (not recorded).
      # The available one fails → all attempted failed → :all_backends_failed.
      assert {:error, :all_backends_failed, %{attempts: attempts}} = result
      assert length(attempts) == 1
      assert {:error, :primary_fails, :primary_failed} = hd(attempts)
      assert_receive {:adapter_called, :primary_fails}
      refute_received {:adapter_called, :unavailable}
    end
  end

  # AC 4: No candidates available + fail_on_unavailable: true → return :no_available_backend
  describe "AC 4: No available backends - returns no_available_backend" do
    test "empty catalog returns no_available_backend without invoking adapter" do
      catalog = start_test_catalog(:ac4_empty)
      sup_name = start_inv_sup(:ac4_empty)

      # Don't register any adapters - empty catalog

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fail_on_unavailable: true
        )

      # Should return :no_available_backend
      assert result == {:error, :no_available_backend}
    end

    test "no matching task type returns no_available_backend" do
      catalog = start_test_catalog(:ac4_task)
      sup_name = start_inv_sup(:ac4_task)

      # Register adapter that only supports :coding, not :chat
      defmodule CodingOnlyAdapter do
        @behaviour BackendAdapter
        @impl true
        def name, do: :coding_only
        @impl true
        def capabilities,
          do: %{
            type: :language_model,
            strengths: [:coding],
            weaknesses: [],
            supported_contexts: [:coding]
          }

        @impl true
        def available?, do: true
        @impl true
        def execute(_request, _opts), do: {:ok, "should not reach", %{}}
      end

      {:ok, _} = AdapterCatalog.register(CodingOnlyAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          # Not supported by adapter
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fail_on_unavailable: true
        )

      # Should return :no_available_backend - adapter doesn't support :chat
      assert result == {:error, :no_available_backend}
    end
  end

  # AC-004-2: Skip unavailable candidates (don't call, don't record)
  describe "AC-004-2: Skip unavailable candidates" do
    test "unavailable primary is skipped, available fallback is used" do
      catalog = start_test_catalog(:ac0042)
      sup_name = start_inv_sup(:ac0042)

      # Register unavailable adapter first, then available fallback
      {:ok, _} = AdapterCatalog.register(UnavailableAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(FallbackSucceedsAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fallback: true,
          max_attempts: 2
        )

      # Should succeed with fallback (unavailable was skipped)
      assert result == {:ok, "fallback response"}

      # Verify fallback was called (unavailable was NOT called)
      assert_receive {:adapter_called, :fallback_succeeds}
      # UnavailableAdapter should NOT have been called
      # (no message means it wasn't invoked)
    end

    test "all candidates unavailable returns no_available_backend" do
      catalog = start_test_catalog(:ac0042_all)
      sup_name = start_inv_sup(:ac0042_all)

      # Register only unavailable adapter
      {:ok, _} = AdapterCatalog.register(UnavailableAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fallback: true,
          max_attempts: 2
        )

      # Should return no_available_backend (skipped all)
      assert result == {:error, :no_available_backend}
    end
  end

  # Manual strategy tests
  describe "Manual strategy with fallback" do
    test "manual strategy executes single adapter" do
      catalog = start_test_catalog(:manual)
      sup_name = start_inv_sup(:manual)

      defmodule ManualSuccessAdapter do
        @behaviour BackendAdapter
        @impl true
        def name, do: :manual_success
        @impl true
        def capabilities,
          do: %{
            type: :language_model,
            strengths: [:coding],
            weaknesses: [],
            supported_contexts: [:chat]
          }

        @impl true
        def available?, do: true
        @impl true
        def execute(request, _opts) do
          send(request.context.test_pid, {:adapter_called, :manual_success})
          {:ok, "manual success", %{}}
        end
      end

      {:ok, _} = AdapterCatalog.register(ManualSuccessAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :manual,
          backend: :manual_success,
          catalog: catalog,
          invocation_supervisor: sup_name
        )

      assert result == {:ok, "manual success"}
      assert_receive {:adapter_called, :manual_success}
    end

    test "manual strategy with unknown backend returns error" do
      catalog = start_test_catalog(:manual_unknown)
      sup_name = start_inv_sup(:manual_unknown)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :manual,
          backend: :nonexistent,
          catalog: catalog,
          invocation_supervisor: sup_name
        )

      assert result == {:error, :no_available_backend}
    end
  end

  # TRD-008-TEST: explicit attempt limits — max_attempts cap on a candidate list
  # longer than the cap. Call order, call count, and exact attempt history are
  # asserted.
  describe "TRD-008-TEST: explicit attempt limits" do
    test "max_attempts=2 caps at 2 attempts when 3 candidates are available" do
      catalog = start_test_catalog(:t008_limit)
      sup_name = start_inv_sup(:t008_limit)

      # Three failing adapters. Order in registration: primary_fails (cost 0.001),
      # third_fails (cost 0.003), both_fail (no cost → sorts last). With
      # max_attempts=2, only the first two are tried.
      {:ok, _} = AdapterCatalog.register(PrimaryFailsAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(ThirdFailsAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(BothFailAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fallback: true,
          max_attempts: 2
        )

      assert {:error, :all_backends_failed, %{attempts: attempts}} = result
      assert length(attempts) == 2
      assert {:error, :primary_fails, :primary_failed} = hd(attempts)
      assert {:error, :third_fails, :third_failed} = Enum.at(attempts, 1)

      # Exactly two adapters called in execution order; both_fail is excluded.
      # Drain all adapter_called messages and compare the received-name list to
      # the expected execution order. This avoids pattern-specific receives
      # and proves order plus count plus exclusion in one assertion.
      called =
        for _ <- 1..2 do
          assert_receive {:adapter_called, name}, 100
          name
        end

      assert called == [:primary_fails, :third_fails]
      # Final guard: no further adapter calls (catches duplicates if max_attempts
      # were ever bypassed) and no :both_fail (the third registered adapter).
      refute_receive {:adapter_called, _}, 100
    end

    test "exact attempt history tuples preserve backend name and reason" do
      catalog = start_test_catalog(:t008_history)
      sup_name = start_inv_sup(:t008_history)

      {:ok, _} = AdapterCatalog.register(PrimaryFailsAdapter, catalog)
      {:ok, _} = AdapterCatalog.register(BothFailAdapter, catalog)

      result =
        AgentRuntime.execute("test", %{test_pid: self()},
          strategy: :automatic,
          task_type: :chat,
          catalog: catalog,
          invocation_supervisor: sup_name,
          fallback: true,
          max_attempts: 2
        )

      assert {:error, :all_backends_failed, %{attempts: attempts}} = result

      # Exact attempt history: each attempt is {:error, backend_name, reason}
      # in execution order, with backend name and reason preserved verbatim.
      assert attempts == [
               {:error, :primary_fails, :primary_failed},
               {:error, :both_fail, :both_failed}
             ]
    end
  end
end
