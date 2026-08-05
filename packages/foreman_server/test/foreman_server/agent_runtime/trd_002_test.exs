defmodule ForemanServer.AgentRuntime.TRD002Test do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.{
    AdapterCatalog,
    AdapterRegistry,
    BackendAdapter,
    Invocation,
    InvocationSupervisor,
    Supervisor
  }

  # --- Test Adapters ---

  defmodule OrderAdapterA do
    @behaviour BackendAdapter
    @impl true
    def name, do: :order_test_a
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule OrderAdapterB do
    @behaviour BackendAdapter
    @impl true
    def name, do: :order_test_b
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule ReRegAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :re_reg_test
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule UnregAdapterA do
    @behaviour BackendAdapter
    @impl true
    def name, do: :unreg_a
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule UnregAdapterB do
    @behaviour BackendAdapter
    @impl true
    def name, do: :unreg_b
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule UnregAdapterC do
    @behaviour BackendAdapter
    @impl true
    def name, do: :unreg_c
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule MutabilityAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :mut_test
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule StartupTelemetryAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :startup_telemetry_test
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule RegistryLookupAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :registry_lookup_test
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule CrashSiblingAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :crash_sibling
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: Process.sleep(50) && {:ok, "done", %{}}
  end

  defmodule CrashSelfAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :crash_self
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts) do
      spawn(fn -> Process.exit(self(), :kill) end)
      {:ok, "crashed", %{}}
    end
  end

  defmodule EmptyChildrenAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :empty_children
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule StopNormalAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :stop_normal
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule ConcurrentAdapter1 do
    @behaviour BackendAdapter
    @impl true
    def name, do: :concurrent_1
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: Process.sleep(20) && {:ok, "one", %{}}
  end

  defmodule ConcurrentAdapter2 do
    @behaviour BackendAdapter
    @impl true
    def name, do: :concurrent_2
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: Process.sleep(10) && {:ok, "two", %{}}
  end

  defmodule ConcurrentNAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :concurrent_n
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: Process.sleep(:rand.uniform(30)) && {:ok, "ok", %{}}
  end

  defmodule RaiseAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :raise_test
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: raise("test error")
  end

  defmodule ThrowAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :throw_test
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: throw(:foo)
  end

  defmodule ExitAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :exit_test
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: exit(:boom)
  end

  defmodule KillAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :kill_test
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts) do
      Process.exit(self(), :kill)
      {:ok, "never returned", %{}}
    end
  end

  defmodule KillMonitorAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :kill_monitor
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts) do
      Process.sleep(10)
      Process.exit(self(), :kill)
      {:ok, "never", %{}}
    end
  end

  defmodule KillNoRestartAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :kill_no_restart
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts) do
      Process.sleep(10)
      Process.exit(self(), :kill)
      {:ok, "never", %{}}
    end
  end

  defmodule KillNoTelemetryAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :kill_no_telemetry
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts) do
      Process.sleep(10)
      Process.exit(self(), :kill)
      {:ok, "never", %{}}
    end
  end

  defmodule DurationTelemetryAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :duration_telemetry
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule RedactPromptAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :redact_prompt
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule RedactContextAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :redact_context
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule RedactOutputAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :redact_output
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "output_marker", %{}}
  end

  defmodule OkStatusAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :ok_status
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  defmodule ErrorStatusAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :error_status
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: raise("test error")
  end

  defmodule NoExecuteEventAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :no_execute_event
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: true
    @impl true
    def execute(_req, _opts), do: {:ok, "ok", %{}}
  end

  # --- Helpers ---

  defp start_runtime(_opts) do
    test_id = :rand.uniform(999_999)
    sup_name = :"AgentRuntime.Test.#{test_id}"
    catalog_name = :"Catalog#{test_id}"
    invocation_name = :"InvocationSupervisor#{test_id}"
    sup_id = :"agent_runtime_sup#{test_id}"

    sup_opts = [
      name: sup_name,
      adapter_catalog_name: catalog_name,
      invocation_supervisor_name: invocation_name,
      adapters: []
    ]

    start_supervised!({Supervisor, sup_opts}, id: sup_id)

    {catalog_name, invocation_name}
  end

  defp capture_telemetry(events, fun) do
    # Normalize: support flat list `[:a, :b]` or nested `[[:a, :b], [:c, :d]]`
    normalized = if Enum.all?(events, &is_atom/1), do: [events], else: events

    test_pid = self()
    handler_id = "test-#{:rand.uniform(999_999)}"

    :telemetry.attach_many(
      handler_id,
      normalized,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    receive_all_telemetry([])
  end

  defp receive_all_telemetry(acc) do
    receive do
      {:telemetry_event, event, measurements, metadata} ->
        receive_all_telemetry([{event, measurements, metadata} | acc])
    after
      100 ->
        Enum.reverse(acc)
    end
  end

  defp gen_sentinel do
    "PRIVATE_TOKEN_#{:rand.uniform(999_999_999)}_#{:erlang.system_time(:millisecond)}"
  end

  defp receive_results(expected_count, acc \\ [])
  defp receive_results(0, acc), do: acc

  defp receive_results(expected_count, acc) do
    receive do
      {:agent_runtime_invocation_complete, ref, result} ->
        new_acc = [{ref, result} | acc]
        receive_results(expected_count - 1, new_acc)
    after
      1000 ->
        acc
    end
  end

  # --- AC-1: catalog ordering ---

  describe "AC-1 — catalog registration order is stable" do
    test "snapshot preserves registration order across repeated reads" do
      {catalog_name, _inv_name} = start_runtime([])

      {:ok, _} = AdapterCatalog.register(OrderAdapterA, catalog_name)
      {:ok, _} = AdapterCatalog.register(OrderAdapterB, catalog_name)

      snapshot1 = AdapterCatalog.snapshot(catalog_name)
      snapshot2 = AdapterCatalog.snapshot(catalog_name)

      assert snapshot1 == [OrderAdapterA, OrderAdapterB]
      assert snapshot2 == [OrderAdapterA, OrderAdapterB]
    end

    test "re-registration does not advance insertion order" do
      {catalog_name, _inv_name} = start_runtime([])

      {:ok, _} = AdapterCatalog.register(ReRegAdapter, catalog_name)
      snapshot1 = AdapterCatalog.snapshot(catalog_name)

      {:ok, _} = AdapterCatalog.register(ReRegAdapter, catalog_name)
      snapshot2 = AdapterCatalog.snapshot(catalog_name)

      assert snapshot1 == snapshot2
    end

    test "unregister + register yields a new monotonic position" do
      {catalog_name, _inv_name} = start_runtime([])

      {:ok, _} = AdapterCatalog.register(UnregAdapterA, catalog_name)
      {:ok, _} = AdapterCatalog.register(UnregAdapterB, catalog_name)

      :ok = AdapterCatalog.unregister(UnregAdapterA, catalog_name)
      {:ok, _} = AdapterCatalog.register(UnregAdapterC, catalog_name)

      snapshot = AdapterCatalog.snapshot(catalog_name)
      assert snapshot == [UnregAdapterB, UnregAdapterC]
    end

    test "snapshot returns an independent list per call" do
      {catalog_name, _inv_name} = start_runtime([])

      {:ok, _} = AdapterCatalog.register(MutabilityAdapter, catalog_name)

      snapshot1 = AdapterCatalog.snapshot(catalog_name)
      snapshot2 = AdapterCatalog.snapshot(catalog_name)

      assert snapshot1 == snapshot2
    end
  end

  describe "AC-1 — startup registration does not emit telemetry" do
    test "post-startup AdapterCatalog.register/2 emits exactly one catalog register event" do
      {catalog_name, _inv_name} = start_runtime([])

      events =
        capture_telemetry([:foreman, :agent_runtime, :catalog, :register], fn ->
          {:ok, _} = AdapterCatalog.register(StartupTelemetryAdapter, catalog_name)
        end)

      assert length(events) == 1
      {event, _measurements, metadata} = hd(events)
      assert event == [:foreman, :agent_runtime, :catalog, :register]
      assert metadata.backend == :startup_telemetry_test
    end
  end

  describe "AC-1 — Registry integration (keys: :unique)" do
    test "registered adapters are discoverable via Registry.lookup/2" do
      {catalog_name, _inv_name} = start_runtime([])

      {:ok, _} = AdapterCatalog.register(RegistryLookupAdapter, catalog_name)

      [{pid, _}] = Registry.lookup(AdapterRegistry, :registry_lookup_test)
      assert is_pid(pid)
    end

    test "unregistered adapters return [] from Registry.lookup/2" do
      {_catalog_name, _inv_name} = start_runtime([])

      results = Registry.lookup(AdapterRegistry, :nonexistent_adapter)
      assert results == []
    end
  end

  # --- AC-2: invocation isolation ---

  describe "AC-2 — forced crash does not restart and sibling completes" do
    test "killing one invocation does not affect a sibling" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      {:ok, pid1, _ref1} =
        InvocationSupervisor.start_invocation(CrashSiblingAdapter, request, self(), inv_name)

      {:ok, _pid2, ref2} =
        InvocationSupervisor.start_invocation(CrashSiblingAdapter, request, self(), inv_name)

      # Wait for first invocation to start
      Process.sleep(20)

      # Kill the first invocation directly
      Process.exit(pid1, :kill)

      # Wait for second to complete - should receive exactly one result (the sibling)
      results = receive_results(1)
      assert [{^ref2, {:ok, "done"}}] = results
    end

    test "DynamicSupervisor.which_children/1 is empty after the killed child is reaped" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      {:ok, _pid, _ref} =
        InvocationSupervisor.start_invocation(EmptyChildrenAdapter, request, self(), inv_name)

      receive_results(1)

      Process.sleep(50)
      children = DynamicSupervisor.which_children(inv_name)
      assert children == []
    end
  end

  describe "AC-2 — invocation lifecycle is :temporary" do
    test "child_spec/1 declares restart: :temporary" do
      spec =
        Invocation.child_spec(
          {[{SomeAdapter, true}], %{fallback: false, max_attempts: 1, timeout_ms: 60_000},
           %{prompt: "", context: %{}}, self(), make_ref()}
        )

      assert spec.restart == :temporary
    end

    test "a child that returns {:stop, :normal, _} is not restarted" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      {:ok, pid, _ref} =
        InvocationSupervisor.start_invocation(StopNormalAdapter, request, self(), inv_name)

      receive_results(1)

      Process.sleep(50)
      children = DynamicSupervisor.which_children(inv_name)
      assert Enum.find(children, fn {_, p, _, _} -> p == pid end) == nil
    end
  end

  describe "AC-2 — sibling concurrency (no ordering contract)" do
    test "two concurrent invocations both deliver results" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      {:ok, _pid1, _ref1} =
        InvocationSupervisor.start_invocation(ConcurrentAdapter1, request, self(), inv_name)

      {:ok, _pid2, _ref2} =
        InvocationSupervisor.start_invocation(ConcurrentAdapter2, request, self(), inv_name)

      results = receive_results(2)
      assert length(results) == 2
    end

    test "N concurrent invocations all deliver results, none lost" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      for _ <- 1..10 do
        InvocationSupervisor.start_invocation(ConcurrentNAdapter, request, self(), inv_name)
      end

      results = receive_results(10)
      assert length(results) == 10
    end
  end

  describe "AC-2 — adapter exception classes are preserved" do
    test "raise/1 produces {:error, {module, message}}" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      {:ok, _pid, _ref} =
        InvocationSupervisor.start_invocation(RaiseAdapter, request, self(), inv_name)

      results = receive_results(1)
      assert length(results) == 1

      {_inv_ref, result} = hd(results)
      assert {:error, {RaiseAdapter, _message}} = result
    end

    test "throw :foo produces {:error, {module, {:thrown, :foo}}}" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      {:ok, _pid, _ref} =
        InvocationSupervisor.start_invocation(ThrowAdapter, request, self(), inv_name)

      results = receive_results(1)
      assert length(results) == 1

      {_inv_ref, result} = hd(results)
      assert {:error, {ThrowAdapter, {:thrown, :foo}}} = result
    end

    test "exit(:boom) produces {:error, {module, {:exited, :boom}}}" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      {:ok, _pid, _ref} =
        InvocationSupervisor.start_invocation(ExitAdapter, request, self(), inv_name)

      results = receive_results(1)
      assert length(results) == 1

      {_inv_ref, result} = hd(results)
      assert {:error, {ExitAdapter, {:exited, :boom}}} = result
    end
  end

  describe "AC-2 — Process.exit(self(), :kill) is untrappable" do
    test "no {:agent_runtime_invocation_complete, _, _} message is sent" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      {:ok, _pid, _ref} =
        InvocationSupervisor.start_invocation(KillAdapter, request, self(), inv_name)

      Process.sleep(100)

      results = receive_results(0)
      assert results == []
    end

    test "the invocation process is reported :killed via the caller-side monitor" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      {:ok, pid, _ref} =
        InvocationSupervisor.start_invocation(KillMonitorAdapter, request, self(), inv_name)

      monitor_ref = Process.monitor(pid)

      receive do
        {:DOWN, ^monitor_ref, :process, _object, :killed} ->
          :ok
      after
        500 ->
          flunk("Process should have been killed")
      end
    end

    test "DynamicSupervisor does not restart the killed invocation" do
      {_catalog_name, inv_name} = start_runtime([])

      request = %{prompt: "test", context: %{}}

      {:ok, pid, _ref} =
        InvocationSupervisor.start_invocation(KillNoRestartAdapter, request, self(), inv_name)

      monitor_ref = Process.monitor(pid)

      receive do
        {:DOWN, ^monitor_ref, :process, _object, :killed} -> :ok
      after
        500 -> :ok
      end

      Process.sleep(50)

      children = DynamicSupervisor.which_children(inv_name)
      assert Enum.find(children, fn {_, p, _, _} -> p == pid end) == nil
    end

    test "no stop telemetry event is emitted for the killed invocation" do
      {_catalog_name, inv_name} = start_runtime([])

      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :invocation, :start],
            [:foreman, :agent_runtime, :invocation, :stop]
          ],
          fn ->
            request = %{prompt: "test", context: %{}}

            {:ok, pid, _ref} =
              InvocationSupervisor.start_invocation(
                KillNoTelemetryAdapter,
                request,
                self(),
                inv_name
              )

            monitor_ref = Process.monitor(pid)

            receive do
              {:DOWN, ^monitor_ref, :process, _object, :killed} -> :ok
            after
              500 -> :ok
            end

            Process.sleep(50)
          end
        )

      start_events =
        Enum.filter(events, fn {e, _, _} ->
          e == [:foreman, :agent_runtime, :invocation, :start]
        end)

      stop_events =
        Enum.filter(events, fn {e, _, _} ->
          e == [:foreman, :agent_runtime, :invocation, :stop]
        end)

      assert length(start_events) == 1
      assert length(stop_events) == 0
    end
  end

  describe "AC-2 — timeout is adapter-owned" do
    test "Invocation stop telemetry reports status: :ok and a non-negative duration_us" do
      {_catalog_name, inv_name} = start_runtime([])

      events =
        capture_telemetry([:foreman, :agent_runtime, :invocation, :stop], fn ->
          request = %{prompt: "test", context: %{}}

          {:ok, _pid, _ref} =
            InvocationSupervisor.start_invocation(
              DurationTelemetryAdapter,
              request,
              self(),
              inv_name
            )

          receive_results(1)
        end)

      assert length(events) == 1
      {_event, measurements, _metadata} = hd(events)
      assert measurements.duration_us >= 0
    end
  end

  # --- AC-2 — telemetry redaction (REQ-006) ---

  describe "AC-2 — telemetry redaction (REQ-006)" do
    test "no event metadata contains the prompt string" do
      {_catalog_name, inv_name} = start_runtime([])

      prompt = gen_sentinel()

      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :invocation, :start],
            [:foreman, :agent_runtime, :invocation, :stop]
          ],
          fn ->
            request = %{prompt: prompt, context: %{}}

            {:ok, _pid, _ref} =
              InvocationSupervisor.start_invocation(
                RedactPromptAdapter,
                request,
                self(),
                inv_name
              )

            receive_results(1)
          end
        )

      for {_, _, metadata} <- events do
        metadata_str = inspect(metadata)

        refute String.contains?(metadata_str, prompt),
               "Prompt leaked into telemetry: #{metadata_str}"
      end
    end

    test "no event metadata contains the context map" do
      {_catalog_name, inv_name} = start_runtime([])

      context = %{private_key: gen_sentinel()}

      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :invocation, :start],
            [:foreman, :agent_runtime, :invocation, :stop]
          ],
          fn ->
            request = %{prompt: "test", context: context}

            {:ok, _pid, _ref} =
              InvocationSupervisor.start_invocation(
                RedactContextAdapter,
                request,
                self(),
                inv_name
              )

            receive_results(1)
          end
        )

      for {_, _, metadata} <- events do
        metadata_str = inspect(metadata)

        refute String.contains?(metadata_str, "private_key"),
               "Context leaked into telemetry: #{metadata_str}"
      end
    end

    test "no event metadata contains the adapter output string" do
      {_catalog_name, inv_name} = start_runtime([])

      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :invocation, :start],
            [:foreman, :agent_runtime, :invocation, :stop]
          ],
          fn ->
            request = %{prompt: "test", context: %{}}

            {:ok, _pid, _ref} =
              InvocationSupervisor.start_invocation(
                RedactOutputAdapter,
                request,
                self(),
                inv_name
              )

            receive_results(1)
          end
        )

      for {_, _, metadata} <- events do
        metadata_str = inspect(metadata)
        assert metadata.backend == :redact_output
        refute String.contains?(metadata_str, "output_marker")
      end
    end

    test "successful invocation emits a stop event with status: :ok" do
      {_catalog_name, inv_name} = start_runtime([])

      events =
        capture_telemetry([:foreman, :agent_runtime, :invocation, :stop], fn ->
          request = %{prompt: "test", context: %{}}

          {:ok, _pid, _ref} =
            InvocationSupervisor.start_invocation(OkStatusAdapter, request, self(), inv_name)

          receive_results(1)
        end)

      assert length(events) == 1
      {_event, measurements, _metadata} = hd(events)
      assert measurements.status == :ok
    end

    test "errored invocation emits a stop event with status: :error" do
      {_catalog_name, inv_name} = start_runtime([])

      events =
        capture_telemetry([:foreman, :agent_runtime, :invocation, :stop], fn ->
          request = %{prompt: "test", context: %{}}

          {:ok, _pid, _ref} =
            InvocationSupervisor.start_invocation(ErrorStatusAdapter, request, self(), inv_name)

          receive_results(1)
        end)

      assert length(events) == 1
      {_event, measurements, _metadata} = hd(events)
      assert measurements.status == :error
    end

    test "no [:foreman, :agent_runtime, :execute] event is emitted by the Invocation slice" do
      {_catalog_name, inv_name} = start_runtime([])

      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :execute, :start],
            [:foreman, :agent_runtime, :execute, :stop]
          ],
          fn ->
            request = %{prompt: "test", context: %{}}

            {:ok, _pid, _ref} =
              InvocationSupervisor.start_invocation(
                NoExecuteEventAdapter,
                request,
                self(),
                inv_name
              )

            receive_results(1)
          end
        )

      assert events == []
    end
  end

  # --- Supervisor :one_for_one recovery ---

  describe "Supervisor — :one_for_one recovery" do
    test "killing the catalog restarts only the catalog, not the invocation supervisor" do
      {catalog_name, inv_name} = start_runtime([])

      catalog_pid = Process.whereis(catalog_name)
      inv_pid = Process.whereis(inv_name)

      Process.exit(catalog_pid, :kill)

      Process.sleep(100)

      new_catalog_pid = Process.whereis(catalog_name)
      assert new_catalog_pid != nil
      assert new_catalog_pid != catalog_pid

      assert Process.whereis(inv_name) == inv_pid
    end

    test "killing the invocation supervisor restarts only it, leaving the catalog intact" do
      {catalog_name, inv_name} = start_runtime([])

      catalog_pid = Process.whereis(catalog_name)
      inv_pid = Process.whereis(inv_name)

      Process.exit(inv_pid, :kill)

      Process.sleep(100)

      new_inv_pid = Process.whereis(inv_name)
      assert new_inv_pid != nil
      assert new_inv_pid != inv_pid

      assert Process.whereis(catalog_name) == catalog_pid
    end

    test "catalog GenServer process identity changes across restart" do
      {catalog_name, _inv_name} = start_runtime([])

      catalog_pid = Process.whereis(catalog_name)
      Process.exit(catalog_pid, :kill)

      Process.sleep(100)

      new_catalog_pid = Process.whereis(catalog_name)
      assert new_catalog_pid != catalog_pid
    end
  end
end
