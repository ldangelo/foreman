defmodule JidoHarnessSmokeTest do
  @moduledoc """
  TRD-2026-8a1f3c2e / TRD-001 smoke test.

  Verifies the vendored `jido_harness` library is exercisable from a
  consumer (`packages/foreman_server` or any other Mix project that
  depends on `{:jido_harness, path: "../jido_harness"}`) by:

    1. Defining a local stub adapter that implements `Jido.Harness.Adapter`.
    2. Registering it under `Application.put_env(:jido_harness, :providers, ...)`.
    3. Asserting `Jido.Harness.run(:pi, "ping", [])` returns
       `{:ok, %Jido.Harness.RunResult{status: :completed, ...}}`.
    4. Asserting `Jido.Harness.status(:pi)` returns
       `{:ok, %Jido.Harness.ProviderStatus{provider: :pi, installed: true}}`.

  No real CLI is invoked; this is offline-friendly and deterministic.

  Run from `packages/jido_harness/`:
      SHELL=/bin/bash mix test test/smoke_test.exs
  """

  use ExUnit.Case, async: false

  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  defmodule Stub do
    @moduledoc "Local stub adapter for the TRD-001 smoke test."
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "TRD-001 smoke stub",
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

  test "vendored Jido.Harness module is reachable from a consumer" do
    assert Code.ensure_loaded?(Jido.Harness),
           "Jido.Harness module not loaded — vendoring incomplete"

    exports = Jido.Harness.__info__(:functions)
    assert {:run, 3} in exports,
           "Jido.Harness.run/3 must be exported (got functions: #{inspect(exports)})"

    assert Enum.any?(Jido.Harness.providers(), &(&1.provider == :pi)),
           ":pi provider should be registered via Application.put_env stub"
  end

  test "Jido.Harness.run/3 with stub adapter returns a completed RunResult" do
    result = Jido.Harness.run(:pi, "ping", [])

    assert {:ok, run_result} = result,
           "expected {:ok, %RunResult{}}, got: #{inspect(result)}"

    assert %Jido.Harness.RunResult{} = run_result
    assert run_result.status == :completed
    # Stronger assertion: prove the canonical event path was taken, not
    # the upstream fallback. The stub emits :output_text_final with
    # %{"text" => "pong"} and a :run_completed terminal event. If the
    # fallback (terminal_event: nil) was used, text would be nil and
    # the run_completed counter would be lower.
    assert run_result.text == "pong",
           "expected run_result.text == \"pong\" (from stub event), got: #{inspect(run_result.text)}"
  end

  test "Jido.Harness.status/1 returns {:ok, %ProviderStatus{provider: :pi, installed: true}}" do
    result = Jido.Harness.status(:pi)

    assert {:ok, %ProviderStatus{} = status} = result,
           "expected {:ok, %ProviderStatus{}}, got: #{inspect(result)}"

    assert status.provider == :pi
    assert status.installed == true
  end
end
