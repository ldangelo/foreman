defmodule ForemanServer.AgentRuntime.TRD003Test do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.{AdapterCatalog, BackendAdapter, Supervisor}

  # Test adapters - captures prompt/context for verification
  defmodule EchoAdapter do
    @behaviour BackendAdapter

    @impl true
    def name, do: :echo_adapter

    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}

    @impl true
    def available?, do: true

    @impl true
    def execute(%{prompt: prompt, context: context}, _opts) do
      # Echo back prompt and context for verification
      {:ok, "prompt=#{prompt} context=#{inspect(context)}", %{}}
    end
  end

  defmodule UnavailableAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :unavailable_adapter
    @impl true
    def capabilities, do: %{type: :cli, strengths: [], weaknesses: [], supported_contexts: []}
    @impl true
    def available?, do: false
    @impl true
    def execute(_req, _opts), do: {:ok, "success", %{}}
  end

  defp start_runtime do
    test_id = :rand.uniform(999_999)
    sup_name = :"AgentRuntime.Test.#{test_id}"
    catalog_name = :"Catalog#{test_id}"
    invocation_name = :"InvocationSup#{test_id}"
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

  describe "execute/3 manual routing" do
    test "passes exact prompt and context to adapter, returns content only" do
      {catalog_name, inv_name} = start_runtime()

      # Register adapter with the test catalog
      {:ok, _} = AdapterCatalog.register(EchoAdapter, catalog_name)

      # Execute with specific prompt and context
      result =
        ForemanServer.AgentRuntime.execute("my test prompt", %{key: "value"},
          strategy: :manual,
          backend: :echo_adapter,
          catalog: catalog_name,
          invocation_supervisor: inv_name
        )

      # Verify success returns only content (no backend name)
      assert {:ok, "prompt=my test prompt context=%{key: \"value\"}"} = result
    end

    test "returns {:error, :backend_not_found} for unknown backend" do
      {catalog_name, inv_name} = start_runtime()

      # Register EchoAdapter, then request a different (nonexistent) backend
      {:ok, _} = AdapterCatalog.register(EchoAdapter, catalog_name)

      result =
        ForemanServer.AgentRuntime.execute("test prompt", %{},
          strategy: :manual,
          backend: :nonexistent,
          catalog: catalog_name,
          invocation_supervisor: inv_name
        )

      assert {:error, :backend_not_found} = result
    end

    test "returns {:error, :backend_unavailable} for unavailable backend - no fallback" do
      {catalog_name, inv_name} = start_runtime()

      # Register unavailable adapter
      {:ok, _} = AdapterCatalog.register(UnavailableAdapter, catalog_name)

      # Execute - should return unavailable, NOT try another adapter
      result =
        ForemanServer.AgentRuntime.execute("test prompt", %{},
          strategy: :manual,
          backend: :unavailable_adapter,
          catalog: catalog_name,
          invocation_supervisor: inv_name
        )

      assert {:error, :backend_unavailable} = result
    end

    test "returns {:error, :no_available_backend} for empty catalog" do
      # Start runtime with empty catalog
      {catalog_name, inv_name} = start_runtime()

      # Execute with no adapters registered
      result =
        ForemanServer.AgentRuntime.execute("test prompt", %{},
          strategy: :manual,
          backend: :any_backend,
          catalog: catalog_name,
          invocation_supervisor: inv_name
        )

      # Empty catalog should return no_available_backend immediately
      assert {:error, :no_available_backend} = result
    end
  end

  describe "telemetry metadata schema (REQ-006 — exactly two keys)" do
    test "start event metadata is exactly %{strategy, backend}" do
      {catalog_name, inv_name} = start_runtime()
      {:ok, _} = AdapterCatalog.register(EchoAdapter, catalog_name)

      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :execute, :start],
            [:foreman, :agent_runtime, :execute, :stop]
          ],
          fn ->
            ForemanServer.AgentRuntime.execute("p", %{},
              strategy: :manual,
              backend: :echo_adapter,
              catalog: catalog_name,
              invocation_supervisor: inv_name
            )
          end
        )

      [start_event, _stop_event] = events
      {_name, _start_measurements, start_metadata} = start_event
      assert Map.keys(start_metadata) |> Enum.sort() == [:backend, :strategy]
      assert start_metadata.strategy == :manual
      assert start_metadata.backend == :echo_adapter
    end

    test "stop event metadata is exactly %{strategy, backend} — status/attempts are measurements" do
      {catalog_name, inv_name} = start_runtime()
      {:ok, _} = AdapterCatalog.register(EchoAdapter, catalog_name)

      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :execute, :start],
            [:foreman, :agent_runtime, :execute, :stop]
          ],
          fn ->
            ForemanServer.AgentRuntime.execute("p", %{},
              strategy: :manual,
              backend: :echo_adapter,
              catalog: catalog_name,
              invocation_supervisor: inv_name
            )
          end
        )

      [_start_event, stop_event] = events
      {_name, stop_measurements, stop_metadata} = stop_event
      assert Map.keys(stop_metadata) |> Enum.sort() == [:backend, :strategy]
      assert Map.has_key?(stop_measurements, :status)
      assert Map.has_key?(stop_measurements, :attempts)
      assert Map.has_key?(stop_measurements, :duration_us)
      assert stop_measurements.status == :ok
      assert stop_measurements.attempts == 1
    end

    test "error-path stop event has status/attempts in measurements, not metadata" do
      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :execute, :start],
            [:foreman, :agent_runtime, :execute, :stop]
          ],
          fn ->
            ForemanServer.AgentRuntime.execute("p", %{},
              strategy: :manual,
              backend: :nonexistent
            )
          end
        )

      [_start_event, stop_event] = events
      {_name, stop_measurements, stop_metadata} = stop_event
      assert Map.keys(stop_metadata) |> Enum.sort() == [:backend, :strategy]
      assert stop_measurements.status == :backend_not_found
      assert stop_measurements.attempts == 0
    end

    test "nil backend emits start+stop with backend: nil metadata (early-error short-circuit)" do
      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :execute, :start],
            [:foreman, :agent_runtime, :execute, :stop]
          ],
          fn ->
            assert {:error, :backend_not_found} =
                     ForemanServer.AgentRuntime.execute("p", %{},
                       strategy: :manual,
                       backend: nil
                     )
          end
        )

      assert length(events) == 2
      [start_event, stop_event] = events
      {_n, _sm, start_meta} = start_event
      {_n, stop_meas, stop_meta} = stop_event
      assert Map.keys(start_meta) |> Enum.sort() == [:backend, :strategy]
      assert start_meta.backend == nil
      assert start_meta.strategy == :manual
      assert Map.keys(stop_meta) |> Enum.sort() == [:backend, :strategy]
      assert stop_meta.backend == nil
      assert stop_meas.status == :backend_not_found
      assert stop_meas.attempts == 0
    end
  end

  # --- Helpers (mirrored from TRD002Test for telemetry capture) ---

  defp capture_telemetry(events, fun) do
    normalized =
      if Enum.all?(events, &is_atom/1) do
        [events]
      else
        events
      end

    test_pid = self()
    handler_id = "trd003-test-#{:rand.uniform(999_999)}"

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
      100 -> Enum.reverse(acc)
    end
  end
end
