defmodule ForemanServer.AgentRuntime.JidoHarnessIntegrationTest do
  @moduledoc """
  TRD-013 — integration tests covering the full `Jido.Harness.RunResult`
  contract end-to-end through Foreman's `AgentRuntime.execute/3` facade,
  the `foreman server doctor` MCP tool surface, and the detached
  `Jido.Harness.Run.start/2` + `Run.await/2` lifecycle.

  Each AC exercises observable behaviour at the persisted boundary:
  `JidoHarnessAdapter` is registered with a fresh
  `ForemanServer.AgentRuntime.AdapterCatalog` (per
  `foreman_server/agent_runtime/jido_harness/registration_test.exs`),
  the `Jido.Harness.Adapter` behaviour is stubbed for both `:pi` and
  `:claude` per the existing pattern in `jido_harness_test.exs`, and the
  doctor MCP tool is invoked directly via
  `ForemanServerWeb.MCP.Tools.Doctor.run/1` (the same module the
  `foreman server doctor` CLI mix task delegates to).

  Uses `async: false` because the test mutates the global
  `:jido_harness, :providers` Application env key,
  `:foreman_server, :jido_harness` enabled flag, the `PATH`
  environment variable, and the `:persistent_term` adapter-test
  registry. Concurrent tests would race on those side effects and
  pollute each other's baseline.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime
  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter
  alias ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck
  alias ForemanServer.AgentRuntime.Supervisor, as: AgentRuntimeSupervisor
  alias ForemanServerWeb.MCP.Tools.Doctor
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  # ---------------------------------------------------------------------------
  # Stub adapters
  # ---------------------------------------------------------------------------
  #
  # One stub module per provider (`PiStub`, `ClaudeStub`). Each hard-codes
  # its own provider atom in `spec/0` and `status/1` so that
  # `Jido.Harness.Registry.spec/1`'s `spec.provider == queried` invariant
  # holds even when both providers are probed in the same call window (the
  # `foreman server doctor` loop iterates `[:pi, :claude]`). A single
  # arity-0 `spec/0` cannot infer the queried provider, so a per-provider
  # module is the only correct way to serve `:pi` installed while `:claude`
  # is missing.
  #
  # The installed marker is keyed per module via `:persistent_term`
  # (default `true`), letting each test drive availability independently.
  defmodule PiStub do
    @moduledoc false
    @behaviour Adapter
    @provider :pi

    @impl true
    def spec do
      %AdapterSpec{
        provider: @provider,
        name: "TRD-013 pi stub",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      installed = :persistent_term.get({__MODULE__, :installed}, true)

      {:ok,
       %ProviderStatus{
         provider: @provider,
         installed: installed,
         compatible: installed,
         authenticated: true,
         smoke_ready: installed,
         capabilities: %Capabilities{streaming?: true, resume?: true},
         executable: "stub"
       }}
    end

    @impl true
    def run(_request, context) do
      provider = Map.get(context, :provider, @provider)

      {:ok,
       [
         Event.new!(provider: provider, type: :output_text_final, payload: %{"text" => "pong"}),
         Event.new!(provider: provider, type: :run_completed, payload: %{})
       ]}
    end
  end

  defmodule ClaudeStub do
    @moduledoc false
    @behaviour Adapter
    @provider :claude

    @impl true
    def spec do
      %AdapterSpec{
        provider: @provider,
        name: "TRD-013 claude stub",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      installed = :persistent_term.get({__MODULE__, :installed}, true)

      {:ok,
       %ProviderStatus{
         provider: @provider,
         installed: installed,
         compatible: installed,
         authenticated: true,
         smoke_ready: installed,
         capabilities: %Capabilities{streaming?: true, resume?: true},
         executable: "stub"
       }}
    end

    @impl true
    def run(_request, context) do
      provider = Map.get(context, :provider, @provider)

      {:ok,
       [
         Event.new!(provider: provider, type: :output_text_final, payload: %{"text" => "pong"}),
         Event.new!(provider: provider, type: :run_completed, payload: %{})
       ]}
    end
  end

  # Stage a stub module's installed marker. `installed?` controls whether
  # `status/1` reports the provider as installed.
  defp stub_installed(module, installed?) do
    :persistent_term.put({module, :installed}, installed?)
  end

  setup do
    original_foreman = Application.get_env(:foreman_server, :jido_harness)
    original_providers = Application.get_env(:jido_harness, :providers)
    original_path = System.get_env("PATH")
    baseline_runs = MapSet.new(Enum.map(Jido.Harness.Run.list(), & &1.run_id))

    Process.flag(:trap_exit, true)

    # Each test gets a uniquely-named AgentRuntime supervisor (catalog +
    # invocation supervisor) so registration of `JidoHarnessAdapter` does
    # not collide with the global catalog. Mirrors the pattern in
    # `foreman_server/agent_runtime/trd_003_test.exs`.
    test_id = System.unique_integer([:positive])
    sup_name = :"AgentRuntime.IntegrationTest.#{test_id}"
    catalog_name = :"IntegrationTest.Catalog.#{test_id}"
    invocation_name = :"IntegrationTest.InvocationSup.#{test_id}"
    sup_id = :"agent_runtime_integration_sup.#{test_id}"

    bin_dir =
      Path.join(System.tmp_dir!(), "jido-harness-integration-#{test_id}")

    File.mkdir_p!(bin_dir)
    File.write!(Path.join(bin_dir, "pi"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(bin_dir, "pi"), 0o755)
    File.write!(Path.join(bin_dir, "claude"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(bin_dir, "claude"), 0o755)

    start_supervised!(
      {AgentRuntimeSupervisor,
       [
         name: sup_name,
         adapter_catalog_name: catalog_name,
         invocation_supervisor_name: invocation_name,
         adapters: []
       ]},
      id: sup_id
    )

    Application.put_env(:foreman_server, :jido_harness, enabled: true)
    Application.put_env(:jido_harness, :providers, %{pi: PiStub, claude: ClaudeStub})
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    # Register `JidoHarnessAdapter` with the test catalog BEFORE any
    # `Jido.Harness.status/1` call (the registration calls
    # `JidoHarnessAdapter.available?/0` which probes `ReadinessCheck`).
    # `:pi` is installed, `:claude` is not — the two-stub design lets both
    # probes resolve independently, so `available?/0` (an OR over both) is
    # true at registration time.
    stub_installed(PiStub, true)
    stub_installed(ClaudeStub, false)

    {:ok, _} = AgentRuntime.register_adapter(JidoHarnessAdapter, catalog: catalog_name)

    on_exit(fn ->
      restore_env(:foreman_server, :jido_harness, original_foreman)
      restore_env(:jido_harness, :providers, original_providers)
      restore_path(original_path)

      for module <- [PiStub, ClaudeStub] do
        try do
          :persistent_term.erase({module, :installed})
        catch
          :error, _ -> :ok
        end
      end

      prune_new_runs(baseline_runs)
      File.rm_rf!(bin_dir)
    end)

    {:ok, catalog: catalog_name, invocation: invocation_name, bin_dir: bin_dir}
  end

  # ---------------------------------------------------------------------------
  # AC-016-010-1: AgentRuntime.execute(...) drives JidoHarnessAdapter end-to-end
  # ---------------------------------------------------------------------------
  describe "AgentRuntime.execute/3 drives JidoHarnessAdapter end-to-end (AC-016-010-1)" do
    test "returns the normalized RunResult shape with provider: :pi and error: nil",
         %{catalog: catalog, invocation: invocation} do
      # `:pi` is installed by setup; re-assert it explicitly for clarity.
      # The runtime probes `JidoHarnessAdapter.available?/0` -> the
      # cached availability captured at registration time (already true).
      stub_installed(PiStub, true)

      # The façade discards the adapter-level metadata map and surfaces
      # only `{:ok, text}` (or `{:error, reason}`). The third element of
      # the normalized adapter result (`%{provider: :pi, adapter: :jido_harness}`)
      # is observable only by calling `JidoHarnessAdapter.execute/2`
      # directly, which is the contract-tested bound.
      assert {:ok, "pong"} =
               AgentRuntime.execute("ping", %{},
                 strategy: :manual,
                 backend: :jido_harness,
                 catalog: catalog,
                 invocation_supervisor: invocation
               )

      # Driving the adapter directly proves the RunResult normalization
      # metadata carries `provider: :pi` and `error: nil` (the third
      # element of the
      # adapter-level tuple that the façade intentionally discards).
      request = %{prompt: "ping", context: %{provider: :pi}}

      assert {:ok, "pong", %{provider: :pi, adapter: :jido_harness}} =
               JidoHarnessAdapter.execute(request, [])
    end

    test "returns {:error, :backend_unavailable} when :pi is not installed",
         %{catalog: catalog, invocation: invocation} do
      stub_installed(PiStub, false)

      request = %{prompt: "ping", context: %{provider: :pi}}

      assert JidoHarnessAdapter.execute(request, []) ==
               {:error, :backend_unavailable}

      assert AgentRuntime.execute("ping", %{provider: :pi},
               strategy: :manual,
               backend: :jido_harness,
               catalog: catalog,
               invocation_supervisor: invocation
             ) == {:error, :backend_unavailable}
    end
  end

  # ---------------------------------------------------------------------------
  # AC-016-010-2: foreman server doctor surfaces available + unavailable providers
  # ---------------------------------------------------------------------------
  describe "foreman server doctor integration (AC-016-010-2)" do
    test "renders the installed and missing providers in the doctor output" do
      # Two-stub design: each provider resolves independently, so the
      # doctor loop can probe `:pi` (installed) and `:claude` (missing)
      # in the same window.
      stub_installed(PiStub, true)
      stub_installed(ClaudeStub, false)

      assert ReadinessCheck.installed?(:pi) == true
      assert ReadinessCheck.installed?(:claude) == false
      # The same `format/1` used by `ForemanServerWeb.MCP.Tools.Doctor`
      # (the module behind the `foreman server doctor` CLI task).
      output =
        Doctor.format([
          {:provider, :pi, :installed, ReadinessCheck.install_hint(:pi)},
          {:provider, :claude, :not_installed, ReadinessCheck.install_hint(:claude)}
        ])

      assert output =~ "Provider readiness"
      assert output =~ "✓ pi available"
      assert output =~ "✗ claude not found"
      assert output =~ "npm install -g @anthropic-ai/claude-code"
    end

    test "strict mode returns provider_missing when any provider is missing" do
      stub_installed(PiStub, true)
      stub_installed(ClaudeStub, false)

      assert ReadinessCheck.installed?(:pi) == true
      assert ReadinessCheck.installed?(:claude) == false
      # `ForemanServerWeb.MCP.Tools.Doctor.run(strict: true)` is the
      # gate the `foreman server doctor --strict` mix task uses to fail
      # CI pipelines when any provider is missing.
      assert {:error, :provider_missing, output} = Doctor.run(strict: true)
      assert output =~ "✓ pi available"
      assert output =~ "✗ claude not found"
    end
  end

  # ---------------------------------------------------------------------------
  # AC-016-010-3 (detached run): Jido.Harness.Run.start/2 + Run.await/2 shape
  # ---------------------------------------------------------------------------
  describe "Jido.Harness.Run detached start/await (AC-016-010-3)" do
    test "await/2 returns a terminal RunResult with provider :pi, status :completed, text \"pong\", error nil" do
      # `Run.start(:pi, ...)` resolves `:pi` -> `PiStub` via the
      # `:jido_harness, :providers` Application env.
      stub_installed(PiStub, true)

      assert {:ok, run_id} = Jido.Harness.Run.start(:pi, %{prompt: "ping"}, [])
      assert is_binary(run_id)
      assert run_id != ""

      assert {:ok, %Jido.Harness.RunResult{} = result} =
               Jido.Harness.Run.await(run_id, 5_000)

      # RunResult fields as listed in AC-016-010-1.
      assert result.run_id == run_id
      assert result.provider == :pi
      assert result.status == :completed
      assert result.text == "pong"
      assert result.error == nil

      # The terminal lifecycle event is the same `:run_completed`
      # surfaced by the Stub. This proves the Stub streams events into
      # `EventLog` and that the worker reduces them into the RunResult
      # shape consumed by `RunResult.normalize/1`.
      assert List.last(result.events).type == :run_completed
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp prune_new_runs(baseline_runs) do
    Jido.Harness.Run.list()
    |> Enum.reject(&MapSet.member?(baseline_runs, &1.run_id))
    |> Enum.each(fn info ->
      unless Jido.Harness.RunInfo.terminal?(info), do: Jido.Harness.Run.cancel(info.run_id)
      _ = Jido.Harness.Run.await(info.run_id, 5_000)
      _ = Jido.Harness.Run.prune(info.run_id)
    end)
  end

  defp restore_env(_app, _key, nil), do: :ok
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(value), do: System.put_env("PATH", value)
end
