defmodule ForemanServer.AgentRuntime.JidoHarness.DetachedRunTest do
  @moduledoc """
  TRD-010 — covers `ForemanServer.AgentRuntime.JidoHarness.DetachedRun`,
  the explicit `start_run/3`, `await_run/2`, `cancel_run/1` façade around
  `Jido.Harness.Run`.

  Uses `async: false` because the test mutates the global
  `:jido_harness, :providers` Application env key, the
  `:jido_harness, :provider_config` retention settings, and the
  upstream `Jido.Harness.RunRegistry`. Concurrent tests would race on
  those side effects and pollute each other's baseline.

  The single `Stub` module is registered as `:pi` per the TRD-010
  contract. The stub distinguishes two prompt shapes:
    - `"ok"` — emits a single `:run_completed` event with text and
      finishes cleanly so `await_run/2` returns immediately.
    - `"wait"` — emits a stream of `:thinking_delta` events without a
      terminal event, keeping the run alive so `cancel_run/1` can be
      observed on a still-running invocation.

  The stub also implements `cancel/2` to emit a `:run_cancelled` event
  back to the run owner. The worker has already finalized by the time
  the event arrives, so this exercises the "stub emits a
  `:run_cancelled` event when called" contract without changing the
  observed terminal status.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.DetachedRun
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  defmodule Stub do
    @moduledoc false
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "TRD-010 detached-run stub",
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
    def run(request, context) do
      case request.prompt do
        "wait" ->
          {:ok,
           Stream.repeatedly(fn ->
             Event.new!(provider: :pi, type: :thinking_delta, payload: %{"text" => "."})
           end)}
          |> tap_starting(context)

        _ ->
          {:ok,
           [
             Event.new!(provider: :pi, type: :output_text_final, payload: %{"text" => "stub-ok"}),
             Event.new!(provider: :pi, type: :run_completed, payload: %{})
           ]}
      end
    end

    @impl true
    def cancel(_run_id, context) do
      send(context.run_owner, {:adapter_event, cancelled_event()})
      :ok
    end

    defp tap_starting(stream, _context), do: stream

    defp cancelled_event do
      Event.new!(provider: :pi, type: :run_cancelled, payload: %{"reason" => "cancelled"})
    end
  end

  setup do
    original_providers = Application.get_env(:jido_harness, :providers)
    original_config = Application.get_env(:jido_harness, :provider_config)
    original_default = Application.get_env(:jido_harness, :default_provider)

    journal_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-detached-run-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(journal_dir)

    Application.put_env(:jido_harness, :providers, %{pi: Stub})

    Application.put_env(:jido_harness, :provider_config, %{
      pi: %{retention: %{journal_dir: journal_dir}}
    })

    Application.delete_env(:jido_harness, :default_provider)

    on_exit(fn ->
      restore_env(:providers, original_providers)
      restore_env(:provider_config, original_config)
      restore_env(:default_provider, original_default)
      cleanup_runs()
      File.rm_rf!(journal_dir)
    end)

    :ok
  end

  describe "start_run/3" do
    test "returns {:ok, run_id} for the :pi provider with a valid request" do
      assert {:ok, run_id} = DetachedRun.start_run(:pi, %{prompt: "ok"}, [])
      assert is_binary(run_id)
      assert run_id != ""
    end
  end

  describe "await_run/2" do
    test "returns the terminal RunResult once the stub finishes with :run_completed" do
      assert {:ok, run_id} = DetachedRun.start_run(:pi, %{prompt: "ok"}, [])

      assert {:ok, %Jido.Harness.RunResult{} = result} = DetachedRun.await_run(run_id, 5_000)

      assert result.run_id == run_id
      assert result.provider == :pi
      assert result.status == :completed
      assert result.text == "stub-ok"
      assert List.last(result.events).type == :run_completed
    end
  end

  describe "cancel_run/1" do
    test "returns :ok while the underlying run is still alive" do
      assert {:ok, run_id} = DetachedRun.start_run(:pi, %{prompt: "wait"}, [])
      assert :ok = DetachedRun.cancel_run(run_id)
    end
  end

  describe "cancel_run/1 + await_run/2" do
    test "await_run observes status: :cancelled after cancel_run is requested" do
      assert {:ok, run_id} = DetachedRun.start_run(:pi, %{prompt: "wait"}, [])
      assert :ok = DetachedRun.cancel_run(run_id)

      assert {:ok, %Jido.Harness.RunResult{} = result} = DetachedRun.await_run(run_id, 5_000)

      assert result.run_id == run_id
      assert result.provider == :pi
      assert result.status == :cancelled
      assert List.last(result.events).type == :run_cancelled
    end
  end

  defp cleanup_runs do
    Jido.Harness.Run.list()
    |> Enum.each(fn info ->
      unless Jido.Harness.RunInfo.terminal?(info), do: Jido.Harness.Run.cancel(info.run_id)
      Jido.Harness.Run.prune(info.run_id)
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore_env(key, value), do: Application.put_env(:jido_harness, key, value)
end
