defmodule ForemanServer.AgentRuntime.JidoHarness.DriverTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.Driver
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  # `Driver` is a thin wrapper over `Jido.Harness.run/3` and
  # `Jido.Harness.Run.await/2`. It does not emit telemetry (the adapter's
  # `emit_stop/4` owns that), does not inject a runner/awaiter, and does
  # not catch upstream exceptions — those responsibilities live in
  # `JidoHarnessAdapter`. These tests pin the actual delegation contract.
  defmodule Stub do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "driver-test stub",
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
    def run(request, _context) do
      if pid = Application.get_env(:jido_harness, :driver_test_pid) do
        send(pid, {:stub_run, request})
      end

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
    original_pid = Application.get_env(:jido_harness, :driver_test_pid)

    Application.put_env(:jido_harness, :providers, %{pi: Stub})
    Application.put_env(:jido_harness, :driver_test_pid, self())

    on_exit(fn ->
      Application.put_env(:jido_harness, :providers, original)

      if original_pid do
        Application.put_env(:jido_harness, :driver_test_pid, original_pid)
      else
        Application.delete_env(:jido_harness, :driver_test_pid)
      end
    end)

    :ok
  end

  describe "module reachability" do
    test "is loadable from consumer code" do
      assert Code.ensure_loaded?(Driver)
    end
  end

  describe "run/3" do
    test "returns a terminal RunResult for a successful upstream run" do
      assert {:ok, %Jido.Harness.RunResult{} = result} = Driver.run(:pi, "ping", [])
      assert result.provider == :pi
      assert result.status == :completed
      assert result.text == "pong"
      assert is_binary(result.run_id)
    end

    test "maps the :timeout option into the upstream :runtime_timeout_ms" do
      assert {:ok, %Jido.Harness.RunResult{}} =
               Driver.run(:pi, "ping", timeout: 4_321)

      assert_receive {:stub_run, request}
      assert request.runtime_timeout_ms == 4_321
    end

    test "keeps an explicit :runtime_timeout_ms over the :timeout option" do
      assert {:ok, %Jido.Harness.RunResult{}} =
               Driver.run(:pi, "ping", timeout: 4_321, runtime_timeout_ms: 1_000)

      assert_receive {:stub_run, request}
      assert request.runtime_timeout_ms == 1_000
    end
  end

  describe "await/2" do
    test "delegates to Jido.Harness.Run.await/2 and returns the terminal RunResult" do
      assert {:ok, run_id} = Jido.Harness.Run.start(:pi, %{prompt: "ping"}, [])

      assert {:ok, %Jido.Harness.RunResult{} = result} = Driver.await(run_id, 5_000)
      assert result.run_id == run_id
      assert result.provider == :pi
      assert result.status == :completed
      assert result.text == "pong"
    end
  end
end
