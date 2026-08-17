defmodule ForemanServer.AgentRuntime.AutomaticTelemetryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.{AdapterCatalog, BackendAdapter, Supervisor}

  alias ForemanServer.TestSupport.InvocationSupervisorHelpers

  # Test adapter for automatic routing
  defmodule CodeAdapter do
    @behaviour BackendAdapter
    @impl true
    def name, do: :code_adapter
    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [:code],
        weaknesses: [],
        supported_contexts: [:code],
        cost_per_call: 0.001,
        typical_latency_ms: 100
      }

    @impl true
    def available?, do: true
    @impl true
    def execute(%{prompt: prompt}, _opts), do: {:ok, "processed: #{prompt}", %{}}
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

    InvocationSupervisorHelpers.schedule_erase()

    start_supervised!({Supervisor, sup_opts}, id: sup_id)

    {catalog_name, invocation_name}
  end

  defp capture_telemetry(events, fun) do
    normalized =
      if Enum.all?(events, &is_atom/1) do
        [events]
      else
        events
      end

    test_pid = self()
    handler_id = "auto-tel-#{:rand.uniform(999_999)}"

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

  describe "execute/3 automatic routing" do
    test "emits start+stop telemetry with strategy: :automatic and backend: selected_name" do
      {catalog_name, inv_name} = start_runtime()
      {:ok, _} = AdapterCatalog.register(CodeAdapter, catalog_name)

      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :execute, :start],
            [:foreman, :agent_runtime, :execute, :stop]
          ],
          fn ->
            result =
              ForemanServer.AgentRuntime.execute("test prompt", %{},
                strategy: :automatic,
                task_type: :code,
                catalog: catalog_name,
                invocation_supervisor: inv_name
              )

            assert {:ok, _} = result
          end
        )

      assert length(events) == 2
      [start_event, stop_event] = events

      {_n, _start_meas, start_meta} = start_event
      {_n, stop_meas, stop_meta} = stop_event

      # Verify metadata keys
      assert Map.keys(start_meta) |> Enum.sort() == [:backend, :strategy]
      assert Map.keys(stop_meta) |> Enum.sort() == [:backend, :strategy]

      # Verify strategy
      assert start_meta.strategy == :automatic
      assert stop_meta.strategy == :automatic

      # Verify backend is the selected adapter's name
      assert start_meta.backend == :code_adapter
      assert stop_meta.backend == :code_adapter

      # Verify measurements
      assert stop_meas.status == :ok
      assert stop_meas.attempts == 1
      assert stop_meas.duration_us > 0
    end

    test "emits telemetry with backend: nil when no available backend" do
      {catalog_name, _inv_name} = start_runtime()

      # Don't register any adapter - catalog stays empty

      events =
        capture_telemetry(
          [
            [:foreman, :agent_runtime, :execute, :start],
            [:foreman, :agent_runtime, :execute, :stop]
          ],
          fn ->
            result =
              ForemanServer.AgentRuntime.execute("test prompt", %{},
                strategy: :automatic,
                task_type: :code,
                catalog: catalog_name
              )

            assert {:error, :no_available_backend} = result
          end
        )

      assert length(events) == 2
      [start_event, stop_event] = events

      {_n, _start_meas, start_meta} = start_event
      {_n, stop_meas, stop_meta} = stop_event

      # Metadata should still have correct keys
      assert Map.keys(start_meta) |> Enum.sort() == [:backend, :strategy]
      assert Map.keys(stop_meta) |> Enum.sort() == [:backend, :strategy]

      # Backend should be nil when no adapter selected
      assert start_meta.backend == nil
      assert stop_meta.backend == nil
      assert start_meta.strategy == :automatic
      assert stop_meta.strategy == :automatic

      # Measurements for no available backend: attempts=0 because no
      # backend was invoked (parallels the manual nil-backend path).
      assert stop_meas.status == :no_available_backend
      assert stop_meas.attempts == 0
    end
  end
end
