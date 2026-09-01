defmodule ForemanServer.AgentRuntime.JidoHarnessTest do
  @moduledoc """
  TRD-008 — covers `ForemanServer.AgentRuntime.JidoHarness` namespace
  helpers and the `:claude` provider path through
  `ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter.execute/2`.

  The namespace module exposes the canonical provider list and
  provider-keyed helpers for the jido_harness integration. The adapter
  delegates provider selection to `JidoHarness.request_provider/1`.

  Uses `async: false` because the test mutates the global
  `:jido_harness, :providers` Application env key, the
  `:foreman_server, :jido_harness` enabled flag, and the `PATH`
  environment variable. Concurrent tests would race on those side
  effects and pollute each other's baseline.

  The single `Stub` module is registered as both `:pi` and `:claude`
  per the TRD-008 contract. The current provider is driven by the
  process dictionary (set by each test via `stub_provider/2`). The
  `:persistent_term` keyed by provider controls whether the stub
  reports the provider as installed or not installed.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter
  alias ForemanServer.AgentRuntime.JidoHarness
  alias ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  defmodule Stub do
    @moduledoc false
    @behaviour Adapter

    @impl true
    def spec do
      provider = current_provider()

      %AdapterSpec{
        provider: provider,
        name: "TRD-008 stub",
        executable: "stub",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      provider = current_provider()

      case :persistent_term.get({__MODULE__, provider}, :installed) do
        :installed ->
          {:ok,
           %ProviderStatus{
             provider: provider,
             installed: true,
             compatible: true,
             authenticated: true,
             smoke_ready: true,
             capabilities: %Capabilities{streaming?: true, resume?: true},
             executable: "stub"
           }}

        :not_installed ->
          {:ok,
           %ProviderStatus{
             provider: provider,
             installed: false,
             compatible: false,
             authenticated: :unknown,
             smoke_ready: false,
             capabilities: %Capabilities{streaming?: false, resume?: false},
             executable: nil
           }}
      end
    end

    @impl true
    def run(_request, context) do
      # The provider is sourced from the context that `Jido.Harness.Run.start`
      # builds — it carries `:provider` as a required field. Reading from
      # the context (rather than the process dictionary) keeps the stub
      # self-contained when `run/2` is invoked in a child process.
      provider = Map.get(context, :provider, :pi)

      {:ok,
       [
         Event.new!(provider: provider, type: :output_text_final, payload: %{"text" => "pong"}),
         Event.new!(provider: provider, type: :run_completed, payload: %{})
       ]}
    end

    defp current_provider do
      Process.get(:jido_harness_current_provider, :pi)
    end
  end

  setup do
    {:ok, _started} = Application.ensure_all_started(:jido_harness)

    original_foreman = Application.get_env(:foreman_server, :jido_harness)
    original_providers = Application.get_env(:jido_harness, :providers)
    original_path = System.get_env("PATH")

    # Defensive: write `pi`/`claude` binaries to PATH so any vendored
    # provider-status probe that resolves the executable (e.g.
    # `Jido.Harness.Adapters.Helpers.probe/2`) finds a stub executable
    # even when the `Jido.Harness.Adapter` stub is in control. The
    # stub returned by `status/1` is the source of truth for the
    # `installed` flag observed by `ReadinessCheck.installed?/1`.
    bin_dir =
      Path.join(System.tmp_dir!(), "jido-harness-trd008-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bin_dir)
    File.write!(Path.join(bin_dir, "pi"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(bin_dir, "pi"), 0o755)
    File.write!(Path.join(bin_dir, "claude"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(bin_dir, "claude"), 0o755)

    Application.put_env(:foreman_server, :jido_harness, enabled: true)
    Application.put_env(:jido_harness, :providers, %{pi: Stub, claude: Stub, litellm: Stub})
    System.put_env("PATH", bin_dir <> ":" <> (original_path || ""))

    on_exit(fn ->
      restore_env(:foreman_server, :jido_harness, original_foreman)
      restore_env(:jido_harness, :providers, original_providers)
      restore_path(original_path)
      File.rm_rf!(bin_dir)

      Process.delete(:jido_harness_current_provider)

      for provider <- [:pi, :claude, :litellm] do
        try do
          :persistent_term.erase({Stub, provider})
        catch
          :error, _ -> :ok
        end
      end
    end)

    :ok
  end

  describe "supported?/0" do
    test "returns the canonical list of supported providers" do
      assert JidoHarness.providers() == [:pi, :claude, :litellm]
    end
  end

  describe "provider?/1" do
    test "returns true for supported providers" do
      assert JidoHarness.provider(:pi) == true
      assert JidoHarness.provider(:claude) == true
      assert JidoHarness.provider(:litellm) == true
    end

    test "returns false for unknown atoms and non-atom arguments" do
      assert JidoHarness.provider(:unknown) == false
      assert JidoHarness.provider(:kimi) == false
      assert JidoHarness.provider("pi") == false
      assert JidoHarness.provider("claude") == false
      assert JidoHarness.provider("litellm") == false
      assert JidoHarness.provider(nil) == false
      assert JidoHarness.provider(123) == false
    end
  end

  describe "request_provider/1" do
    test "returns :claude when request.context.provider is :claude" do
      assert JidoHarness.request_provider(%{context: %{provider: :claude}}) == :claude
    end

    test "returns :pi when request.context.provider is :pi" do
      assert JidoHarness.request_provider(%{context: %{provider: :pi}}) == :pi
    end

    test "defaults to :pi when request.context is empty" do
      assert JidoHarness.request_provider(%{context: %{}}) == :pi
    end

    test "defaults to :pi when request.context is missing" do
      assert JidoHarness.request_provider(%{}) == :pi
    end

    test "accepts string provider keys for parity with JSON-decoded contexts" do
      assert JidoHarness.request_provider(%{context: %{"provider" => "claude"}}) == :claude
      assert JidoHarness.request_provider(%{context: %{"provider" => "pi"}}) == :pi
      assert JidoHarness.request_provider(%{context: %{"provider" => "litellm"}}) == :litellm
    end

    test "accepts mixed-case litellm strings from external YAML/JSON contexts" do
      assert JidoHarness.request_provider(%{context: %{"provider" => "LiteLLM"}}) == :litellm
    end

    test "returns unknown atoms unchanged so the adapter can surface :unsupported_provider" do
      assert JidoHarness.request_provider(%{context: %{provider: :kimi}}) == :kimi
    end
  end

  describe "JidoHarnessAdapter.execute/2 — :claude installed" do
    test "returns normalized success metadata with provider: :claude" do
      stub_provider(:claude, :installed)

      request = %{prompt: "ping", context: %{provider: :claude}}

      assert {:ok, "pong", %{provider: :claude, adapter: :jido_harness}} =
               JidoHarnessAdapter.execute(request, [])
    end
  end

  describe "JidoHarnessAdapter.execute/2 — :pi installed (preserves existing parity)" do
    test "returns normalized success metadata with provider: :pi" do
      stub_provider(:pi, :installed)

      request = %{prompt: "ping", context: %{provider: :pi}}

      assert {:ok, "pong", %{provider: :pi, adapter: :jido_harness}} =
               JidoHarnessAdapter.execute(request, [])
    end
  end

  describe "JidoHarnessAdapter.execute/2 — :litellm installed" do
    test "returns normalized success metadata with provider: :litellm" do
      stub_provider(:litellm, :installed)

      request = %{prompt: "ping", context: %{provider: :litellm}}

      assert {:ok, "pong", %{provider: :litellm, adapter: :jido_harness}} =
               JidoHarnessAdapter.execute(request, [])
    end
  end

  describe "JidoHarnessAdapter.execute/2 — :claude missing" do
    test "returns {:error, :backend_unavailable} when :claude is not installed (per-provider check)" do
      stub_provider(:claude, :not_installed)
      stub_provider(:pi, :installed)

      request = %{prompt: "ping", context: %{provider: :claude}}

      assert JidoHarnessAdapter.execute(request, []) == {:error, :backend_unavailable}
    end

    test "the install command is reachable via ReadinessCheck.install_hint/1 (error message references install command)" do
      # The adapter emits `{:error, :backend_unavailable}` for a missing
      # provider, but the install-command path that downstream tooling
      # (doctor MCP, on-call runbook, the install recipe surfaced in
      # the operator error reply) uses is exposed by
      # `ReadinessCheck.install_hint/1`. The TRD-008 AC requires this
      # command to be reachable for the missing-binary path.
      assert ReadinessCheck.install_hint(:claude) =~ "npm install -g @anthropic-ai/claude-code"
    end

    test "the litellm install hint points operators at pi models.json provider config" do
      assert ReadinessCheck.install_hint(:litellm) =~ "~/.pi/agent/models.json"
      assert ReadinessCheck.install_hint(:litellm) =~ "baseUrl"
    end
  end

  describe "JidoHarnessAdapter.execute/2 — no provider in context" do
    test "defaults to :pi when context is empty" do
      stub_provider(:pi, :installed)

      request = %{prompt: "ping", context: %{}}

      assert {:ok, "pong", %{provider: :pi, adapter: :jido_harness}} =
               JidoHarnessAdapter.execute(request, [])
    end
  end

  defp stub_provider(provider, status) do
    Process.put(:jido_harness_current_provider, provider)
    :persistent_term.put({Stub, provider}, status)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(value), do: System.put_env("PATH", value)
end
