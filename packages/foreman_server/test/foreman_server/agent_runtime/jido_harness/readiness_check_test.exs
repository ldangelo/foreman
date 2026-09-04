defmodule ForemanServer.AgentRuntime.JidoHarness.ReadinessCheckTest do
  @moduledoc """
  TRD-005 — covers `ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck`.

  The module consults the vendored `Jido.Harness.status/1` for the
  `:pi` and `:claude` providers, surfaces the `installed?` boolean, the
  install command hint, the `run/0` aggregate, and emits
  `[:foreman, :dispatch, :provider, :check]` telemetry on every
  `installed?/1` call.

  Uses `async: false` because the readiness check mutates the global
  `:jido_harness, :providers` Application env key and the `:telemetry`
  handler table. Concurrent tests would race on those side effects and
  pollute each other's baseline.

  The single `Stub` module is registered as both `:pi` and `:claude`
  per the TRD-005 contract. Polymorphism is driven by `persistent_term`
  keyed by provider (status response) and a one-shot `:persistent_term`
  queue consulted by `Stub.spec/0` for the `run/0` aggregate, where
  both providers are exercised in sequence.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.JidoHarness.ReadinessCheck
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, ProviderStatus}

  @telemetry_event [:foreman, :dispatch, :provider, :check]

  defmodule Stub do
    @moduledoc false
    @behaviour Adapter

    @queue_key {__MODULE__, :queue}

    @impl true
    def spec do
      provider = current_provider()

      %AdapterSpec{
        provider: provider,
        name: "readiness-stub-#{provider}",
        executable: "stub-#{provider}",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      provider = cached_provider()

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
             executable: "stub-#{provider}"
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

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def run(_request, _context), do: {:ok, []}

    # Pop the next provider from the run/0 queue (when one is queued) or
    # fall back to the test's pinned current provider. `Stub.spec/0` is
    # the only consumer of the queue so a single `Jido.Harness.status/1`
    # call (which invokes `spec/0` once and `status/1` once) only advances
    # the queue by one entry — keeping `run/0`'s `[:pi, :claude]` ordering
    # aligned with the test's expectation. `Stub.status/1` then reads the
    # cached provider from the process dictionary.
    defp current_provider do
      case :persistent_term.get(@queue_key, []) do
        [{provider, _} | rest] ->
          :persistent_term.put(@queue_key, rest)
          Process.put(:readiness_current_provider, provider)
          provider

        [] ->
          Process.get(:readiness_current_provider, :pi)
      end
    end

    defp cached_provider do
      Process.get(:readiness_current_provider, :pi)
    end
  end

  setup do
    original_providers = Application.get_env(:jido_harness, :providers, %{})
    Application.put_env(:jido_harness, :providers, %{pi: Stub, claude: Stub})

    on_exit(fn ->
      Application.put_env(:jido_harness, :providers, original_providers)

      for {provider, _} <- [{:pi, nil}, {:claude, nil}] do
        try do
          :persistent_term.erase({Stub, provider})
        catch
          :error, _ -> :ok
        end
      end

      try do
        :persistent_term.erase({Stub, :queue})
      catch
        :error, _ -> :ok
      end

      Process.delete(:readiness_current_provider)
    end)

    :ok
  end

  describe "installed?/1 — :pi paths" do
    test "returns true when upstream reports the provider is installed" do
      stub_status(:pi, :installed)

      assert ReadinessCheck.installed?(:pi) == true
    end

    test "returns false when upstream reports the provider is not installed" do
      stub_status(:pi, :not_installed)

      assert ReadinessCheck.installed?(:pi) == false
    end

    test "returns false when upstream returns an error tuple" do
      stub_status(:pi, {:error, :probe_failed})

      assert ReadinessCheck.installed?(:pi) == false
    end
  end

  describe "installed?/1 — :claude paths" do
    test "returns true when upstream reports the provider is installed" do
      stub_status(:claude, :installed)

      assert ReadinessCheck.installed?(:claude) == true
    end

    test "returns false when upstream reports the provider is not installed" do
      stub_status(:claude, :not_installed)

      assert ReadinessCheck.installed?(:claude) == false
    end

    test "returns false when upstream returns an error tuple" do
      stub_status(:claude, {:error, :probe_failed})

      assert ReadinessCheck.installed?(:claude) == false
    end
  end

  describe "installed?/1 — unknown provider" do
    test "returns false without invoking upstream" do
      assert ReadinessCheck.installed?(:unknown) == false
      assert ReadinessCheck.installed?(:not_a_real_provider) == false
    end
  end

  describe "install_hint/1" do
    test "returns the npm install command for :pi" do
      assert ReadinessCheck.install_hint(:pi) ==
               "npm install -g @earendil-works/pi-coding-agent"
    end

    test "returns the npm install command for :claude" do
      assert ReadinessCheck.install_hint(:claude) ==
               "npm install -g @anthropic-ai/claude-code"
    end

    test "returns a fallback hint for unknown atoms and non-atom terms" do
      assert ReadinessCheck.install_hint(:unknown) == "unknown provider :unknown"
      assert ReadinessCheck.install_hint("pi") == "unknown provider"
    end
  end

  describe "run/0" do
    test "returns a 4-tuple per supported provider with the provider's install hint" do
      stub_status(:pi, :installed)
      stub_status(:claude, :installed)
      queue_run([{:pi, :installed}, {:claude, :installed}])

      result = ReadinessCheck.run()

      assert {:provider, :pi, :installed, "npm install -g @earendil-works/pi-coding-agent"} in result

      assert {:provider, :claude, :installed, "npm install -g @anthropic-ai/claude-code"} in result
    end

    test "propagates :not_installed for providers that report a missing binary" do
      stub_status(:pi, :not_installed)
      stub_status(:claude, :installed)
      queue_run([{:pi, :not_installed}, {:claude, :installed}])

      result = ReadinessCheck.run()
      pi_tuple = Enum.find(result, &match?({:provider, :pi, _, _}, &1))
      claude_tuple = Enum.find(result, &match?({:provider, :claude, _, _}, &1))

      assert {:provider, :pi, :not_installed, pi_hint} = pi_tuple
      assert pi_hint == "npm install -g @earendil-works/pi-coding-agent"
      assert {:provider, :claude, :installed, claude_hint} = claude_tuple
      assert claude_hint == "npm install -g @anthropic-ai/claude-code"
    end
  end

  describe "telemetry" do
    test "emits [:foreman, :dispatch, :provider, :check] with provider, installed, install_hint metadata" do
      stub_status(:pi, :installed)

      ref =
        :telemetry_test.attach_event_handlers(self(), [@telemetry_event])

      try do
        assert ReadinessCheck.installed?(:pi) == true

        assert_received {@telemetry_event, ^ref, %{}, metadata}

        assert metadata.provider == :pi
        assert metadata.installed == true
        assert metadata.install_hint == "npm install -g @earendil-works/pi-coding-agent"
      after
        :telemetry.detach(ref)
      end
    end

    test "metadata carries installed: false when upstream reports the provider is missing" do
      stub_status(:claude, :not_installed)

      ref =
        :telemetry_test.attach_event_handlers(self(), [@telemetry_event])

      try do
        assert ReadinessCheck.installed?(:claude) == false

        assert_received {@telemetry_event, ^ref, %{}, metadata}

        assert metadata.provider == :claude
        assert metadata.installed == false
        assert metadata.install_hint == "npm install -g @anthropic-ai/claude-code"
      after
        :telemetry.detach(ref)
      end
    end
  end

  defp stub_status(provider, response) do
    Process.put(:readiness_current_provider, provider)
    :persistent_term.put({Stub, provider}, response)
  end

  defp queue_run(pairs) do
    :persistent_term.put({Stub, :queue}, pairs)
  end
end
