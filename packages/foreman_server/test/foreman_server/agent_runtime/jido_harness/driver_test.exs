defmodule ForemanServer.AgentRuntime.JidoHarness.DriverTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.Driver
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  defmodule Stub do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "TRD-003 driver stub",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :pi,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: %Capabilities{streaming?: true, resume?: true},
         executable: "stub"
       }}
    end

    @impl true
    def run(_request, _context) do
      {:ok,
       [
         Event.new!(provider: :pi, type: :output_text_delta, payload: %{"text" => "pong"}),
         Event.new!(provider: :pi, type: :output_text_final, payload: %{"text" => "pong"}),
         Event.new!(provider: :pi, type: :run_completed, payload: %{})
       ]}
    end
  end

  setup do
    original = Application.get_env(:jido_harness, :providers, %{})
    Application.put_env(:jido_harness, :providers, %{pi: Stub})
    on_exit(fn -> Application.put_env(:jido_harness, :providers, original) end)
    :ok
  end

  describe "module reachability" do
    test "is loadable from consumer code" do
      assert Code.ensure_loaded?(Driver)
    end
  end

  describe "run/3" do
    test "returns a terminal RunResult for a successful upstream run" do
      assert {:ok, run_id, %Jido.Harness.RunResult{} = result} = Driver.run(:pi, "ping", [])
      assert run_id == result.run_id
      assert result.provider == :pi
      assert result.status == :completed
      assert result.text == "pong"
    end

    test "awaits detached run ids into a terminal RunResult" do
      run_result =
        Jido.Harness.RunResult.new!(%{
          run_id: "detached-1",
          provider: :pi,
          status: :completed,
          text: "pong"
        })

      runner = fn :pi, "ping", opts when is_list(opts) -> {:ok, "detached-1"} end
      awaiter = fn "detached-1", 123 -> {:ok, run_result} end

      assert {:ok, "detached-1", ^run_result} =
               Driver.run(:pi, "ping", driver_runner: runner, driver_awaiter: awaiter, await_timeout: 123)
    end

    test "catches upstream exceptions and returns an error tuple" do
      runner = fn :pi, "ping", opts when is_list(opts) -> raise "boom" end

      assert {:error, {:driver_exception, :error, %RuntimeError{message: "boom"}}} =
               Driver.run(:pi, "ping", driver_runner: runner)
    end

    test "emits stop telemetry with duration, provider, status, run_id, and adapter" do
      events =
        capture_telemetry([:foreman, :dispatch, :run, :stop], fn ->
          assert {:ok, _run_id, %Jido.Harness.RunResult{}} = Driver.run(:pi, "ping", [])
        end)

      assert [{[:foreman, :dispatch, :run, :stop], measurements, metadata}] = events
      assert is_integer(measurements.duration_ms)
      assert measurements.duration_ms >= 0
      assert metadata.provider == :pi
      assert metadata.status == :ok
      assert metadata.adapter == :jido_harness
      assert is_binary(metadata.run_id)
    end
  end

  defp capture_telemetry(events, fun) do
    test_pid = self()
    handler_id = "driver-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [events],
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
