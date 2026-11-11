defmodule ForemanServerWeb.MCP.Tools.DoctorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.MCP.Tools
  alias ForemanServer.MCP.ToolError
  alias ForemanServerWeb.MCP.Tools.Doctor
  alias Jido.Harness.{Adapter, AdapterSpec, Capabilities, ProviderStatus}

  defmodule StubSupport do
    def status_for(provider) do
      Application.get_env(:foreman_server, :doctor_statuses, %{})
      |> Map.get(provider, {:error, :missing_status})
    end

    def provider_status(provider, installed) do
      %ProviderStatus{
        provider: provider,
        installed: installed,
        compatible: installed,
        authenticated: true,
        smoke_ready: installed,
        capabilities: %Capabilities{streaming?: true, resume?: true},
        executable: Atom.to_string(provider)
      }
    end
  end

  defmodule PiStub do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :pi,
        name: "doctor pi stub",
        executable: "pi",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config), do: StubSupport.status_for(:pi)

    @impl true
    def run(_request, _context), do: {:error, :not_implemented}
  end

  defmodule ClaudeStub do
    @behaviour Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :claude,
        name: "doctor claude stub",
        executable: "claude",
        capabilities: %Capabilities{streaming?: true, resume?: true},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config), do: StubSupport.status_for(:claude)

    @impl true
    def run(_request, _context), do: {:error, :not_implemented}
  end

  setup do
    original_providers = Application.get_env(:jido_harness, :providers, %{})
    original_statuses = Application.get_env(:foreman_server, :doctor_statuses, %{})

    Application.put_env(:jido_harness, :providers, %{pi: PiStub, claude: ClaudeStub})
    Application.put_env(:foreman_server, :doctor_statuses, %{})

    on_exit(fn ->
      Application.put_env(:jido_harness, :providers, original_providers)
      Application.put_env(:foreman_server, :doctor_statuses, original_statuses)
    end)

    :ok
  end

  test "run/0 formats installed and missing providers" do
    put_status(:pi, {:ok, StubSupport.provider_status(:pi, true)})
    put_status(:claude, {:ok, StubSupport.provider_status(:claude, false)})

    assert {:ok, output} = Doctor.run()
    assert output =~ "Provider readiness"
    assert output =~ "✓ pi available"
    assert output =~ "✗ claude not found — install with: npm install -g @anthropic-ai/claude-code"
  end

  test "run(strict: true) returns provider_missing with the rendered report when any provider is missing" do
    put_status(:pi, {:ok, StubSupport.provider_status(:pi, true)})
    put_status(:claude, {:error, :missing})

    assert {:error, :provider_missing, output} = Doctor.run(strict: true)
    assert output =~ "Provider readiness"
    assert output =~ "✗ claude not found — install with: npm install -g @anthropic-ai/claude-code"
  end

  test "MCP tool registry exposes foreman_doctor and returns formatted output" do
    put_status(:pi, {:ok, StubSupport.provider_status(:pi, true)})
    put_status(:claude, {:ok, StubSupport.provider_status(:claude, true)})

    assert Enum.any?(Tools.list_tools(), &(&1.name == "foreman_doctor"))

    assert {:ok, %{output: output}} = Tools.call_tool("foreman_doctor", %{})
    assert output =~ "Provider readiness"
    assert output =~ "✓ pi available"
    assert output =~ "✓ claude available"
  end

  test "MCP tool strict mode returns provider missing error" do
    put_status(:pi, {:ok, StubSupport.provider_status(:pi, false)})
    put_status(:claude, {:ok, StubSupport.provider_status(:claude, true)})

    assert Tools.call_tool("foreman_doctor", %{strict: true}) ==
             {:error,
              %ToolError{
                code: "PROVIDER_MISSING",
                message: "One or more required providers are unavailable"
              }}
  end

  describe "Unresolved effect keys" do
    alias ForemanServer.Idempotency.{Effect, IdempotencyKey, KeyStore}
    alias ForemanServer.ProjectionStore
    alias ForemanServer.TestSupport.{KeyStoreReset, UniqueIds}

    @config ForemanServer.Agents.JidoCheckpointStore

    defmodule AnsweringRepo do
      @moduledoc false
      def all(_query), do: Application.get_env(:foreman_server, :doctor_test_rows, [])
    end

    defmodule DownRepo do
      @moduledoc false
      def all(_query), do: raise(DBConnection.ConnectionError, "connection refused")
    end

    setup do
      original = Application.get_env(:foreman_server, @config, [])

      on_exit(fn ->
        Application.put_env(:foreman_server, @config, original)
        Application.delete_env(:foreman_server, :doctor_test_rows)
        restart_key_store()
        KeyStoreReset.reset!()
      end)

      Application.put_env(:foreman_server, @config, [])
      restart_key_store()
      KeyStoreReset.reset!()
      put_status(:pi, {:ok, StubSupport.provider_status(:pi, true)})
      put_status(:claude, {:ok, StubSupport.provider_status(:claude, true)})
      :ok
    end

    defp restart_key_store do
      Supervisor.terminate_child(ForemanServer.Application, KeyStore)
      {:ok, _pid} = Supervisor.restart_child(ForemanServer.Application, KeyStore)
      :ok
    end

    defp failed_run do
      run_id = UniqueIds.unique_run_id("doctor-effect")

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "RunStarted", payload: %{run_id: run_id, project_id: "p-doctor"}},
          %{
            event_type: "RunFailed",
            payload: %{run_id: run_id, project_id: "p-doctor", reason: "x"}
          }
        ])

      run_id
    end

    # An effect key left `ambiguous` the way boot leaves it: the effect's process died after
    # `Effect.run` recorded `started`, then the sweep marks the orphan ambiguous.
    defp ambiguous_effect(class, run_id, identity) do
      key = Effect.key(class, run_id, identity)
      test = self()

      pid =
        spawn(fn ->
          Effect.run(
            class,
            key,
            fn ->
              send(test, {:in_effect, self()})
              Process.sleep(:infinity)
            end,
            %{"run_id" => run_id, "head_branch" => identity, "cwd" => "/tmp"}
          )
        end)

      assert_receive {:in_effect, ^pid}
      Process.exit(pid, :kill)
      assert {:ok, :started} = KeyStore.status(key)
      :ok = KeyStore.mark_ambiguous(key, "boot_orphan")
      key
    end

    test "lists an ambiguous effect key of a terminal run with its class, run id and status" do
      run_id = failed_run()
      key = ambiguous_effect("branch_push", run_id, "feature/doctor")

      assert {:ok, [entry]} = Doctor.unresolved_effect_keys()
      assert entry == %{key: key, class: "branch_push", run_id: run_id, status: "failed"}

      assert {:ok, output} = Doctor.run()
      assert output =~ "Unresolved effect keys"
      assert output =~ "branch_push run=#{run_id} status=failed key=#{key}"
      # The provider report is still the first part of the output.
      assert output =~ "Provider readiness"
      assert output =~ "✓ pi available"
    end

    test "lists the key whatever the run's status: no projection reads not_found" do
      key = ambiguous_effect("branch_push", "run-no-projection-doctor", "feature/none")

      assert {:ok, [%{key: ^key, status: "not_found"}]} = Doctor.unresolved_effect_keys()
    end

    test "does not list a completed or failed effect key, nor an ambiguous agent-phase key" do
      done = Effect.key("branch_push", "r-done", "a")
      :ok = KeyStore.mark_started(done, %{"run_id" => "r-done", "effect_class" => "branch_push"})
      :ok = KeyStore.mark_completed(done, %{})
      failed = Effect.key("pr_create", "r-fail", "b")
      :ok = KeyStore.mark_started(failed, %{"run_id" => "r-fail", "effect_class" => "pr_create"})
      :ok = KeyStore.mark_failed(failed, "boom")
      :ok = KeyStore.mark_started("phase:r-phase:p1", %{"run_id" => "r-phase"})
      :ok = KeyStore.mark_ambiguous("phase:r-phase:p1", "expired")

      assert {:ok, []} = Doctor.unresolved_effect_keys()
      assert {:ok, output} = Doctor.run()
      refute output =~ "phase:r-phase:p1"
      refute output =~ done
    end

    test "ETS fallback: says the store is not durable and an empty list is not read as clean" do
      assert {:ok, output} = Doctor.run()
      assert output =~ "✗ idempotency store is not durable"
      assert output =~ "FOREMAN_JIDO_ECTO_ENABLED=true"
      assert output =~ "none in this process (keys from before the last restart are not listed)"
      refute output =~ "  none\n"
    end

    test "repo configured and answering: durable store line and a plain none" do
      Application.put_env(:foreman_server, @config, repo: AnsweringRepo)
      restart_key_store()

      assert {:ok, output} = Doctor.run()
      assert output =~ "✓ idempotency store is durable"
      assert output =~ "  none"
      refute output =~ "not listed"
    end

    test "repo rows are listed with string-keyed metadata" do
      Application.put_env(:foreman_server, @config, repo: AnsweringRepo)

      Application.put_env(:foreman_server, :doctor_test_rows, [
        %IdempotencyKey{
          key: "effect:pr_create:run-x:feature/y",
          status: :ambiguous,
          metadata: %{"run_id" => "run-x", "effect_class" => "pr_create"}
        },
        %IdempotencyKey{key: "phase:run-x:p1", status: :ambiguous, metadata: %{}}
      ])

      restart_key_store()

      assert {:ok, [%{class: "pr_create", run_id: "run-x", status: "not_found"}]} =
               Doctor.unresolved_effect_keys()
    end

    test "a record with no usable run_id is listed with status unknown, never crashing" do
      key = Effect.key("task_provider", "r-none", "z")
      :ok = KeyStore.mark_started(key, %{"effect_class" => "task_provider", "run_id" => ""})
      :ok = KeyStore.mark_ambiguous(key, "boot")

      assert {:ok, [%{key: ^key, class: "task_provider", run_id: "unknown", status: "unknown"}]} =
               Doctor.unresolved_effect_keys()
    end

    test "an unreadable store gets a could-not-be-read note, never an empty list; strict is unchanged" do
      Application.put_env(:foreman_server, @config, repo: DownRepo)
      restart_key_store()

      assert {:error, :unavailable} = Doctor.unresolved_effect_keys()
      assert {:ok, output} = Doctor.run(strict: true)
      assert output =~ "Provider readiness"
      assert output =~ "✓ pi available"
      assert output =~ "configured but unreachable"
      assert output =~ "could not be read"
      refute output =~ "  none"
    end

    test "KeyStore not running: the same note, and a missing provider still fails strict" do
      Supervisor.terminate_child(ForemanServer.Application, KeyStore)

      try do
        assert {:error, :unavailable} = Doctor.unresolved_effect_keys()
        assert {:ok, output} = Doctor.run()
        assert output =~ "could not be read"

        put_status(:claude, {:error, :missing})
        assert {:error, :provider_missing, report} = Doctor.run(strict: true)
        assert report =~ "✗ claude not found"
        assert report =~ "could not be read"
      after
        {:ok, _pid} = Supervisor.restart_child(ForemanServer.Application, KeyStore)
      end
    end

    @tag timeout: 30_000
    test "a projection store that does not answer degrades each entry to unknown" do
      run_id = failed_run()
      key = ambiguous_effect("branch_push", run_id, "feature/down")

      :ok = :sys.suspend(ProjectionStore)

      try do
        assert {:ok, [%{key: ^key, class: "branch_push", status: "unknown"}]} =
                 Doctor.unresolved_effect_keys()
      after
        :ok = :sys.resume(ProjectionStore)
      end
    end

    test "rows/0 stays provider rows only" do
      assert Enum.all?(Doctor.rows(), &match?({:provider, _name, _status, _hint}, &1))
    end
  end

  defp put_status(provider, value) do
    statuses = Application.get_env(:foreman_server, :doctor_statuses, %{})
    Application.put_env(:foreman_server, :doctor_statuses, Map.put(statuses, provider, value))
  end
end
