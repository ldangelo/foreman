defmodule ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapterTest do
  use ExUnit.Case, async: false

  alias ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, Event, ProviderStatus}

  defmodule Stub do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "TRD-003 test stub",
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
         provider: :pi,
         installed: installed,
         compatible: installed,
         authenticated: true,
         smoke_ready: installed,
         capabilities: %Capabilities{streaming?: true, resume?: true},
         executable: "stub"
       }}
    end

    @impl true
    def run(request, context) do
      if pid = Application.get_env(:jido_harness, :adapter_test_pid) do
        send(pid, {:stub_run, request, context})
      end

      case request.prompt do
        "ping" ->
          {:ok,
           [
             Event.new!(provider: :pi, type: :output_text_final, payload: %{"text" => "pong"}),
             Event.new!(provider: :pi, type: :run_completed, payload: %{})
           ]}

        "fail" ->
          {:ok,
           [Event.new!(provider: :pi, type: :run_failed, payload: %{"error" => "stub failure"})]}
      end
    end
  end

  setup do
    original_foreman = Application.get_env(:foreman_server, :jido_harness)
    original_providers = Application.get_env(:jido_harness, :providers)
    original_test_pid = Application.get_env(:jido_harness, :adapter_test_pid)
    original_path = System.get_env("PATH")
    baseline_runs = MapSet.new(Enum.map(Jido.Harness.Run.list(), & &1.run_id))

    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "jido-harness-adapter-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    write_executable!(Path.join(tmp_dir, "pi"), "#!/bin/sh\nexit 0\n")

    Application.put_env(:foreman_server, :jido_harness, enabled: true)
    Application.put_env(:jido_harness, :providers, %{pi: Stub})
    Application.put_env(:jido_harness, :adapter_test_pid, self())
    System.put_env("PATH", tmp_dir <> ":" <> (original_path || ""))
    # Stub reports the provider installed by default; individual tests
    # flip this marker to simulate a missing provider (ReadinessCheck now
    # probes Jido.Harness.status/1, not $PATH).
    :persistent_term.put({Stub, :installed}, true)

    on_exit(fn ->
      restore_env(:foreman_server, :jido_harness, original_foreman)
      restore_env(:jido_harness, :providers, original_providers)
      restore_env(:jido_harness, :adapter_test_pid, original_test_pid)
      restore_path(original_path)

      try do
        :persistent_term.erase({Stub, :installed})
      catch
        :error, _ -> :ok
      end

      prune_new_runs(baseline_runs)
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir, original_path: original_path}
  end

  test "module is reachable from consumer code" do
    assert Code.ensure_loaded?(JidoHarnessAdapter)
  end

  test "name/0 returns :jido_harness" do
    assert JidoHarnessAdapter.name() == :jido_harness
  end

  test "capabilities/0 returns the expected map" do
    assert JidoHarnessAdapter.capabilities() == %{
             type: :cli,
             strengths: [:code_generation, :code_review, :refactor],
             weaknesses: [:long_context],
             supported_contexts: [:implement, :refactor, :review, :explain]
           }
  end

  test "available?/0 returns true when enabled and a provider binary is installed" do
    assert JidoHarnessAdapter.available?()
  end

  test "available?/0 returns false when enabled but no provider reports installed",
       %{original_path: original_path} do
    # ReadinessCheck probes Jido.Harness.status/1. Flip the :pi stub
    # marker to not-installed; empty PATH so the built-in :claude adapter
    # (Registry merges @builtins with the test override) also reports
    # not-installed.
    empty_dir =
      Path.join(
        System.tmp_dir!(),
        "jido-harness-adapter-empty-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(empty_dir)
    :persistent_term.put({Stub, :installed}, false)

    try do
      System.put_env("PATH", empty_dir)
      refute JidoHarnessAdapter.available?()
    after
      restore_path(original_path)
      File.rm_rf!(empty_dir)
    end
  end

  test "execute/2 returns normalized success metadata and forwards cwd/env/runtime timeout", %{
    tmp_dir: tmp_dir
  } do
    request = %{prompt: "ping", context: %{provider: :pi, working_directory: tmp_dir}}

    assert {:ok, "pong", %{provider: :pi, adapter: :jido_harness}} =
             JidoHarnessAdapter.execute(request, timeout_ms: 1_234, env: %{"FOO" => "bar"})

    assert_receive {:stub_run, run_request, _context}
    assert run_request.prompt == "ping"
    assert run_request.cwd == tmp_dir
    assert run_request.env == %{"FOO" => "bar"}
    assert run_request.runtime_timeout_ms == 1_234
  end

  test "execute/2 reports the provider's failure category for terminal failed runs" do
    # The stub emits `:run_failed`, so the harness worker finalizes with
    # `%Jido.Harness.Error{category: :execution}`. That category is the only
    # failure detail the provider gave us and it must reach the caller —
    # previously it collapsed to `:unknown_error`.
    request = %{prompt: "fail", context: %{provider: :pi}}

    assert JidoHarnessAdapter.execute(request, []) == {:error, {:other, :execution}}
  end

  describe "normalize_raw_error/1" do
    test "maps a recognized atom reason to its declared code" do
      assert JidoHarnessAdapter.normalize_raw_error(:timeout) == {:error, :timeout}
      assert JidoHarnessAdapter.normalize_raw_error(:cancelled) == {:error, :cancelled}
      assert JidoHarnessAdapter.normalize_raw_error(:tool_error) == {:error, :tool_error}

      assert JidoHarnessAdapter.normalize_raw_error(:process_terminated) ==
               {:error, :process_terminated}

      assert JidoHarnessAdapter.normalize_raw_error(:unsupported_provider) ==
               {:error, :unsupported_provider}
    end

    test "preserves an informative atom reason instead of collapsing it" do
      # `:shutdown` (supervisor terminated the worker) and `:not_found`
      # (`Jido.Harness.Run.await/2` on a vanished run) are both real reasons
      # the old pass-through list reported as `:unknown_error`.
      assert JidoHarnessAdapter.normalize_raw_error(:shutdown) == {:error, {:other, :shutdown}}
      assert JidoHarnessAdapter.normalize_raw_error(:not_found) == {:error, {:other, :not_found}}
    end

    test "maps a %Jido.Harness.Error{} reason through its category" do
      assert JidoHarnessAdapter.normalize_raw_error(Jido.Harness.Error.validation("bad options")) ==
               {:error, {:other, :validation}}
    end

    test "reserves :unknown_error for a reason carrying no failure category" do
      assert JidoHarnessAdapter.normalize_raw_error(nil) == {:error, :unknown_error}
      assert JidoHarnessAdapter.normalize_raw_error("boom") == {:error, :unknown_error}
      assert JidoHarnessAdapter.normalize_raw_error({:exit, :killed}) == {:error, :unknown_error}
      assert JidoHarnessAdapter.normalize_raw_error(%{}) == {:error, :unknown_error}
    end
  end

  test "execute/2 returns {:error, :unsupported_provider} for unknown provider atoms" do
    request = %{prompt: "ping", context: %{provider: :kimi}}

    assert JidoHarnessAdapter.execute(request, []) == {:error, :unsupported_provider}
  end

  test "execute/2 returns {:error, :backend_unavailable} when the requested provider is not installed" do
    # ReadinessCheck.installed?/1 probes Jido.Harness.status/1; flip the
    # stub marker so :pi reports not-installed.
    :persistent_term.put({Stub, :installed}, false)

    assert JidoHarnessAdapter.execute(%{prompt: "ping", context: %{provider: :pi}}, []) ==
             {:error, :backend_unavailable}
  end

  test "execute/2 with provider :claude fails per-provider when :claude is not installed (even if :pi is)",
       %{original_path: original_path} do
    # Create a fake `pi` binary in PATH so :pi is "installed" but :claude is not.
    # This proves the per-provider check uses ReadinessCheck.installed?(provider)
    # and not the OR-check in available?/0.
    tmp =
      Path.join(System.tmp_dir!(), "jido-harness-pi-only-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "pi"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(tmp, "pi"), 0o755)

    try do
      System.put_env("PATH", tmp)

      assert JidoHarnessAdapter.execute(%{prompt: "ping", context: %{provider: :claude}}, []) ==
               {:error, :backend_unavailable}
    after
      restore_path(original_path)
      File.rm_rf!(tmp)
    end
  end

  test "execute/2 emits dispatch stop telemetry with expected metadata" do
    handler_id = attach_telemetry(self(), [[:foreman, :dispatch, :run, :stop]])

    on_exit(fn ->
      :telemetry.detach(handler_id)
    end)

    request = %{prompt: "ping", context: %{provider: :pi}}

    assert {:ok, "pong", %{provider: :pi, adapter: :jido_harness}} =
             JidoHarnessAdapter.execute(request, [])

    assert_receive {:telemetry_event, [:foreman, :dispatch, :run, :stop], measurements, metadata}
    assert is_integer(measurements.duration_ms)
    assert measurements.duration_ms >= 0
    assert metadata.provider == :pi
    assert metadata.status == :ok
    assert metadata.adapter == :jido_harness
    assert is_binary(metadata.run_id)
    assert metadata.run_id != ""
  end

  defp attach_telemetry(pid, events) do
    handler_id = "jido-harness-adapter-test-#{System.unique_integer([:positive, :monotonic])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, owner ->
          send(owner, {:telemetry_event, event, measurements, metadata})
        end,
        pid
      )

    handler_id
  end

  defp prune_new_runs(baseline_runs) do
    Jido.Harness.Run.list()
    |> Enum.reject(&MapSet.member?(baseline_runs, &1.run_id))
    |> Enum.each(fn info ->
      unless Jido.Harness.RunInfo.terminal?(info), do: Jido.Harness.Run.cancel(info.run_id)
      _ = Jido.Harness.Run.await(info.run_id, 5_000)
      _ = Jido.Harness.Run.prune(info.run_id)
    end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp restore_path(nil), do: System.delete_env("PATH")
  defp restore_path(value), do: System.put_env("PATH", value)

  defp write_executable!(path, content) do
    File.write!(path, content)
    File.chmod!(path, 0o755)
  end
end
