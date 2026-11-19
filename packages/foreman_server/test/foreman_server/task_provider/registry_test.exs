defmodule ForemanServer.TaskProvider.RegistryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProvider.Telemetry, as: TaskProviderTelemetry
  alias ForemanServer.Test.Support.CapabilityStubProvider

  @restart_event [:foreman_server, :task_provider, :registry, :restarted]
  @invalid_event [:foreman_server, :task_provider, :registry, :invalid_capabilities]

  defmodule CompatibleProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :compatible

    @impl true
    def capabilities do
      %{
        provider_id: :compatible,
        contract_version: "br.capabilities.v1",
        supports: [:claim],
        storage_scheme: :sqlite
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def list_ready(_project_config, _opts), do: {:ok, []}

    @impl true
    def get(_id, _project_config),
      do: {:error, ForemanServer.TaskProviders.ProviderError.new("test", "unavailable")}

    @impl true
    def claim(_id, _claim_token, _project_config), do: :ok

    @impl true
    def complete(_id, _completion_token, _project_config), do: :ok

    @impl true
    def fail(_id, _failure_token, _project_config), do: :ok

    @impl true
    def reopen(_id, _transition_comment, _project_config), do: :ok

    @impl true
    def set_priority(_id, _priority, _project_config), do: :ok

    @impl true
    def add_dependency(_id, _depends_on_id, _project_config), do: :ok

    @impl true
    def annotate(_id, _body, _project_config), do: {:error, :not_implemented}

    @impl true
    def create(_attrs, _project_config),
      do: {:error, ForemanServer.TaskProviders.ProviderError.new("test", "create not supported")}
  end

  defmodule IncompatibleProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :incompatible

    @impl true
    def capabilities do
      %{
        provider_id: :incompatible,
        contract_version: "br.capabilities.v2",
        supports: [:claim],
        storage_scheme: :sqlite
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def list_ready(_project_config, _opts), do: {:ok, []}

    @impl true
    def get(_id, _project_config),
      do: {:error, ForemanServer.TaskProviders.ProviderError.new("test", "unavailable")}

    @impl true
    def claim(_id, _claim_token, _project_config), do: :ok

    @impl true
    def complete(_id, _completion_token, _project_config), do: :ok

    @impl true
    def fail(_id, _failure_token, _project_config), do: :ok

    @impl true
    def reopen(_id, _transition_comment, _project_config), do: :ok

    @impl true
    def set_priority(_id, _priority, _project_config), do: :ok

    @impl true
    def add_dependency(_id, _depends_on_id, _project_config), do: :ok

    @impl true
    def annotate(_id, _body, _project_config), do: {:error, :not_implemented}

    @impl true
    def create(_attrs, _project_config),
      do: {:error, ForemanServer.TaskProviders.ProviderError.new("test", "create not supported")}
  end

  defmodule ConcurrentProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :concurrent

    @impl true
    def capabilities do
      %{
        provider_id: :concurrent,
        contract_version: "br.capabilities.v1",
        supports: [:claim],
        storage_scheme: :sqlite
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def list_ready(_project_config, _opts), do: {:ok, []}

    @impl true
    def get(_id, _project_config),
      do: {:error, ForemanServer.TaskProviders.ProviderError.new("test", "unavailable")}

    @impl true
    def claim(_id, _claim_token, _project_config), do: :ok

    @impl true
    def complete(_id, _completion_token, _project_config), do: :ok

    @impl true
    def fail(_id, _failure_token, _project_config), do: :ok

    @impl true
    def reopen(_id, _transition_comment, _project_config), do: :ok

    @impl true
    def set_priority(_id, _priority, _project_config), do: :ok

    @impl true
    def add_dependency(_id, _depends_on_id, _project_config), do: :ok

    @impl true
    def annotate(_id, _body, _project_config), do: {:error, :not_implemented}

    @impl true
    def create(_attrs, _project_config),
      do: {:error, ForemanServer.TaskProviders.ProviderError.new("test", "create not supported")}
  end

  defmodule UnavailableProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :unavailable

    @impl true
    def capabilities do
      %{
        provider_id: :unavailable,
        contract_version: "br.capabilities.v1",
        supports: [:claim],
        storage_scheme: :sqlite
      }
    end

    @impl true
    def available?, do: false

    @impl true
    def list_ready(_project_config, _opts), do: {:ok, []}

    @impl true
    def get(_id, _project_config),
      do: {:error, ForemanServer.TaskProviders.ProviderError.new("test", "unavailable")}

    @impl true
    def claim(_id, _claim_token, _project_config), do: :ok

    @impl true
    def complete(_id, _completion_token, _project_config), do: :ok

    @impl true
    def fail(_id, _failure_token, _project_config), do: :ok

    @impl true
    def reopen(_id, _transition_comment, _project_config), do: :ok

    @impl true
    def set_priority(_id, _priority, _project_config), do: :ok

    @impl true
    def add_dependency(_id, _depends_on_id, _project_config), do: :ok

    @impl true
    def annotate(_id, _body, _project_config), do: {:error, :not_implemented}

    @impl true
    def create(_attrs, _project_config),
      do: {:error, ForemanServer.TaskProviders.ProviderError.new("test", "create not supported")}
  end

  setup_all do
    {:ok, _telemetry_apps} = Application.ensure_all_started(:telemetry)
    :ok
  end

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])
    :persistent_term.erase({Registry, Registry, :boot_count})

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      :persistent_term.erase({Registry, Registry, :boot_count})
    end)

    :ok
  end

  test "loads configured providers into the boot snapshot" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: [ForemanServer.TaskProviders.BeadsAdapter]
    )

    name = :task_provider_registry_boot_test
    start_supervised!({Registry, [name: name]}, id: name)

    assert GenServer.call(name, :routing_snapshot) == %{
             beads: ForemanServer.TaskProviders.BeadsAdapter
           }

    assert :sys.get_state(name) == %{
             routing: %{beads: ForemanServer.TaskProviders.BeadsAdapter},
             accepted_versions: ["br.capabilities.v1"],
             per_project: %{}
           }
  end

  test "routing_snapshot/0 merges per-project entries alongside global routing" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: [ForemanServer.TaskProviders.BeadsAdapter]
    )

    name = :task_provider_registry_snapshot_per_project
    start_supervised!({Registry, [name: name]}, id: name)

    :ok =
      GenServer.call(
        name,
        {:register_for_project, "project-1", CompatibleProvider,
         %{
           "database_path" => "/tmp/project-1.db"
         }}
      )

    snapshot = GenServer.call(name, :routing_snapshot)

    assert snapshot.beads == ForemanServer.TaskProviders.BeadsAdapter
    assert snapshot["project-1"] == CompatibleProvider
  end

  test "register rejects incompatible contract versions" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    name = :task_provider_registry_contract_test
    start_supervised!({Registry, [name: name]}, id: name)

    assert {:error, :contract_version_mismatch} =
             GenServer.call(name, {:register, IncompatibleProvider})

    assert {:ok, CompatibleProvider} = GenServer.call(name, {:register, CompatibleProvider})
    assert GenServer.call(name, :routing_snapshot) == %{compatible: CompatibleProvider}
  end

  test "restart emits telemetry and reloads providers" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: [CompatibleProvider]
    )

    handler_id = "task-provider-registry-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @restart_event,
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    name = :task_provider_registry_restart_test
    pid = start_supervised!({Registry, [name: name]}, id: name)

    # Pin the registry: the event is global, and the app-tree Registry may
    # restart (and emit) concurrently with this test.
    refute_receive {:telemetry, @restart_event, _, %{registry: ^name}}, 50

    Process.exit(pid, :shutdown)

    assert_receive {:telemetry, @restart_event, %{count: 1}, metadata}, 1_000
    assert metadata.registry == name
    assert metadata.providers == [:compatible]
    assert metadata.restart_count == 1

    assert GenServer.call(name, :routing_snapshot) == %{compatible: CompatibleProvider}
  end

  test "concurrent registration reflects both registrations in routing_snapshot/0" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    results =
      [CompatibleProvider, ConcurrentProvider]
      |> Task.async_stream(&Registry.register/1,
        max_concurrency: 2,
        ordered: false,
        timeout: 1_000
      )
      |> Enum.to_list()

    assert Enum.sort(results) ==
             Enum.sort([
               {:ok, {:ok, CompatibleProvider}},
               {:ok, {:ok, ConcurrentProvider}}
             ])

    assert Registry.routing_snapshot() == %{
             compatible: CompatibleProvider,
             concurrent: ConcurrentProvider
           }
  end

  test "global register/1 accepts unavailable providers without filtering them out" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    assert {:ok, UnavailableProvider} = Registry.register(UnavailableProvider)
    assert Registry.routing_snapshot().unavailable == UnavailableProvider
    assert {:ok, UnavailableProvider} = Registry.route(:claim, :unavailable)
  end

  test "register_for_project/3 stores per-project routing and route/2 with tuple key returns the provider" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    assert :ok =
             Registry.register_for_project("project-1", CompatibleProvider, %{
               "database_path" => "/tmp/project-1.db"
             })

    assert {:ok, CompatibleProvider} = Registry.route(:claim, {"project-1", "/tmp/project-1.db"})

    assert :sys.get_state(Registry).per_project == %{
             "project-1" =>
               {:active,
                %{
                  provider_module: CompatibleProvider,
                  config: %{"database_path" => "/tmp/project-1.db"}
                }}
           }
  end

  test "register_for_project/3 rejects unavailable providers and unregister_for_project/2 marks unavailable" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    assert {:error, :unavailable} =
             Registry.register_for_project("project-1", UnavailableProvider, %{
               "database_path" => "/tmp/project-1.db"
             })

    assert :ok =
             Registry.register_for_project("project-1", CompatibleProvider, %{
               "database_path" => "/tmp/project-1.db"
             })

    assert :ok = Registry.unregister_for_project("project-1", :database_not_found)

    assert {:error, :provider_unavailable_for_project} =
             Registry.route(:claim, {"project-1", "/tmp/project-1.db"})

    # Recovery: re-registering restores routing.
    assert :ok =
             Registry.register_for_project("project-1", CompatibleProvider, %{
               "database_path" => "/tmp/project-1.db"
             })

    assert {:ok, CompatibleProvider} =
             Registry.route(:claim, {"project-1", "/tmp/project-1.db"})
  end

  test "route/2 returns database_path_mismatch when the project database_path differs" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    :ok =
      Registry.register_for_project("project-1", CompatibleProvider, %{
        "database_path" => "/tmp/project-1.db"
      })

    assert {:error, :database_path_mismatch} =
             Registry.route(:claim, {"project-1", "/tmp/other.db"})
  end

  test "route/2 returns task_provider_not_configured for projects that were never registered" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    assert {:error, :task_provider_not_configured} =
             Registry.route(:claim, {"project-ghost", "/tmp/ghost.db"})
  end

  test "restart-redundancy re-registers config providers" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: [ForemanServer.TaskProviders.BeadsAdapter]
    )

    pid = ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    assert Registry.routing_snapshot() == %{beads: ForemanServer.TaskProviders.BeadsAdapter}

    :ok = :sys.terminate(pid, :kill)
    wait_for_restart(Registry, pid)

    assert Registry.routing_snapshot() == %{beads: ForemanServer.TaskProviders.BeadsAdapter}
  end

  test "[:foreman_server, :task_provider, :registry, :restarted] emitted on restart" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: [ForemanServer.TaskProviders.BeadsAdapter]
    )

    handler_id = "task-provider-registry-restart-event-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        @restart_event,
        &__MODULE__.handle_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    pid = ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    refute_receive {:telemetry, @restart_event, _, %{registry: Registry}}, 50

    :ok = :sys.terminate(pid, :kill)
    wait_for_restart(Registry, pid)

    assert_receive {:telemetry, @restart_event, %{count: 1}, metadata}, 1_000
    assert metadata.registry == Registry
    assert metadata.providers == [:beads]
    assert metadata.restart_count == 1
  end

  describe "TRD-005 :create routing via %{project_id: id} + project_config/1" do
    test "route(:create, %{project_id: id}) returns the registered provider module" do
      assert :ok =
               Registry.register_for_project(
                 "project-create-route",
                 ForemanServer.TaskProviders.BeadsAdapter,
                 %{database_path: "/abs/beads.db"}
               )

      assert {:ok, ForemanServer.TaskProviders.BeadsAdapter} =
               Registry.route(:create, %{project_id: "project-create-route"})
    end

    test "project_config/1 returns {:ok, %{provider_module, config}} for an active project" do
      assert :ok =
               Registry.register_for_project(
                 "project-active",
                 ForemanServer.TaskProviders.BeadsAdapter,
                 %{database_path: "/abs/beads.db"}
               )

      assert {:ok, config} = Registry.project_config("project-active")

      assert config.provider_module == ForemanServer.TaskProviders.BeadsAdapter

      assert config.config == %{database_path: "/abs/beads.db"}
    end

    test "project_config/1 returns {:error, :task_provider_not_configured} for an unknown project" do
      assert {:error, :task_provider_not_configured} =
               Registry.project_config("project-ghost")
    end

    test "project_config/1 returns the registered config map verbatim (empty config: %{} accepted)" do
      assert :ok =
               Registry.register_for_project(
                 "project-empty-config",
                 ForemanServer.TaskProviders.BeadsAdapter,
                 %{}
               )

      assert {:ok, config} = Registry.project_config("project-empty-config")

      assert config.provider_module == ForemanServer.TaskProviders.BeadsAdapter
      assert config.config == %{}
    end

    test "project_config/1 returns {:error, :provider_unavailable_for_project} after unregister" do
      :ok =
        Registry.register_for_project(
          "project-down",
          ForemanServer.TaskProviders.BeadsAdapter,
          %{database_path: "/tmp/project-down.db"}
        )

      :ok = Registry.unregister_for_project("project-down", :br_binary_missing)

      assert {:error, :provider_unavailable_for_project} =
               Registry.project_config("project-down")
    end

    test "project_config/1 returns {:error, :invalid_project_id} for non-binary input" do
      assert {:error, :invalid_project_id} = Registry.project_config(:not_a_string)
    end

    test "route(:create, %{project_id: id}) returns :no_provider for unregistered projects" do
      assert {:error, :no_provider} =
               Registry.route(:create, %{project_id: "project-missing"})
    end

    test "route(:create, %{project_id: id}) returns :capability_not_supported when the registered provider does not advertise :create" do
      assert :ok =
               Registry.register_for_project(
                 "project-no-create",
                 CompatibleProvider,
                 %{database_path: "/tmp/project-no-create.db"}
               )

      assert {:error, :capability_not_supported} =
               Registry.route(:create, %{project_id: "project-no-create"})
    end
  end

  describe "validate_capabilities/1 (TRD-KATA-T030, AC-010-1)" do
    @valid %{
      provider_id: :stub,
      contract_version: "br.capabilities.v1",
      supports: [:claim],
      storage_scheme: :sqlite
    }

    test "accepts every required key at its documented type" do
      assert :ok = Registry.validate_capabilities(@valid)
    end

    test "accepts both storage schemes, an empty supports list, a compilable id_format and unknown keys" do
      assert :ok = Registry.validate_capabilities(%{@valid | storage_scheme: :cli_process})
      assert :ok = Registry.validate_capabilities(%{@valid | supports: []})

      assert :ok =
               Registry.validate_capabilities(
                 Map.merge(@valid, %{id_format: "^[a-z0-9]+$", note: "unknown keys are ignored"})
               )
    end

    for key <- [:provider_id, :contract_version, :supports, :storage_scheme] do
      test "a map without #{key} is rejected, naming that key" do
        assert {:error, [{:missing_key, unquote(key)}]} =
                 Registry.validate_capabilities(Map.delete(@valid, unquote(key)))
      end
    end

    for {key, bad} <- [
          provider_id: "stub",
          provider_id: nil,
          provider_id: true,
          contract_version: :v1,
          contract_version: "",
          supports: :claim,
          supports: ["claim"],
          supports: [:claim | :tail],
          storage_scheme: :postgres,
          storage_scheme: "sqlite",
          storage_scheme: nil,
          id_format: :pattern,
          id_format: "(unclosed"
        ] do
      test "#{key} #{inspect(bad)} is rejected as an invalid value" do
        assert {:error, [{:invalid_value, unquote(key)}]} =
                 Registry.validate_capabilities(
                   Map.put(@valid, unquote(key), unquote(Macro.escape(bad)))
                 )
      end
    end

    test "every violation is reported, required keys first in declaration order, then the optional ones" do
      assert {:error,
              [
                {:missing_key, :provider_id},
                {:invalid_value, :contract_version},
                {:invalid_value, :supports},
                {:missing_key, :storage_scheme},
                {:invalid_value, :id_format}
              ]} =
               Registry.validate_capabilities(%{
                 contract_version: 1,
                 supports: :all,
                 id_format: 7
               })
    end

    test "a declaration that is not a map is rejected" do
      for bad <- [nil, [], "capabilities", [provider_id: :stub]] do
        assert {:error, [:not_a_map]} = Registry.validate_capabilities(bad)
      end
    end
  end

  describe "registry exclusion of invalid capability maps (TRD-KATA-T030, AC-010-1)" do
    setup do
      handler_id = "registry-invalid-capabilities-#{System.unique_integer([:positive])}"
      :ok = :telemetry.attach(handler_id, @invalid_event, &__MODULE__.handle_telemetry/4, self())
      on_exit(fn -> :telemetry.detach(handler_id) end)

      Application.put_env(:foreman_server, :task_provider,
        actor: nil,
        accepted_contract_versions: ["br.capabilities.v1"],
        providers: []
      )

      :ok
    end

    test "a provider with an invalid map is left out of the boot snapshot and reported; valid providers still load" do
      invalid = stub_without_scheme()

      Application.put_env(:foreman_server, :task_provider,
        actor: nil,
        accepted_contract_versions: ["br.capabilities.v1"],
        providers: [CompatibleProvider, invalid]
      )

      name = :task_provider_registry_invalid_boot

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_supervised!({Registry, [name: name]}, id: name)
        end)

      assert log =~ "storage_scheme"
      assert GenServer.call(name, :routing_snapshot) == %{compatible: CompatibleProvider}

      assert_receive {:telemetry, @invalid_event, %{count: 1},
                      %{provider: ^invalid, violations: [{:missing_key, :storage_scheme}]}},
                     1_000
    end

    test "register/1 returns :invalid_capabilities, leaves the snapshot unchanged and reports the provider" do
      invalid = stub_without_scheme()

      Application.put_env(:foreman_server, :task_provider,
        actor: nil,
        accepted_contract_versions: ["br.capabilities.v1"],
        providers: [CompatibleProvider]
      )

      name = :task_provider_registry_invalid_register
      start_supervised!({Registry, [name: name]}, id: name)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :invalid_capabilities} = GenServer.call(name, {:register, invalid})
      end)

      assert GenServer.call(name, :routing_snapshot) == %{compatible: CompatibleProvider}

      assert_receive {:telemetry, @invalid_event, %{count: 1},
                      %{provider: ^invalid, violations: [{:missing_key, :storage_scheme}]}},
                     1_000
    end

    test "register_for_project/3 refuses an invalid provider and registers nothing for the project" do
      invalid = stub_without_scheme()
      ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :invalid_capabilities} =
                 Registry.register_for_project("project-invalid", invalid, %{
                   "database_path" => "/tmp/project-invalid.db"
                 })
      end)

      assert :sys.get_state(Registry).per_project == %{}
      assert_receive {:telemetry, @invalid_event, %{count: 1}, %{provider: ^invalid}}, 1_000
    end

    test "each event names the provider that broke the contract and every key it broke" do
      bad_types =
        CapabilityStubProvider.define!(
          name: :bad_types,
          capabilities: %{
            provider_id: "bad",
            contract_version: "br.capabilities.v1",
            supports: [:claim],
            storage_scheme: :mongo
          }
        )

      not_a_map = CapabilityStubProvider.define!(name: :not_a_map, capabilities: nil)
      ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :invalid_capabilities} = Registry.register(bad_types)
        assert {:error, :invalid_capabilities} = Registry.register(not_a_map)
      end)

      assert_receive {:telemetry, @invalid_event, %{count: 1},
                      %{
                        provider: ^bad_types,
                        violations: [
                          {:invalid_value, :provider_id},
                          {:invalid_value, :storage_scheme}
                        ]
                      }},
                     1_000

      assert_receive {:telemetry, @invalid_event, %{count: 1},
                      %{provider: ^not_a_map, violations: [:not_a_map]}},
                     1_000
    end

    test "validity is judged before the contract version" do
      both =
        CapabilityStubProvider.define!(
          name: :both,
          capabilities: %{
            provider_id: :both,
            contract_version: "br.capabilities.v999",
            supports: [:claim]
          }
        )

      ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, :invalid_capabilities} = Registry.register(both)
      end)
    end

    test "the event is part of the documented telemetry taxonomy" do
      assert %{metadata_keys: [:provider, :violations], scrub_required?: false} =
               TaskProviderTelemetry.taxonomy()[@invalid_event]
    end
  end

  defp wait_for_restart(name, previous_pid, attempts \\ 40)

  defp wait_for_restart(_name, _previous_pid, 0) do
    flunk("registry did not restart")
  end

  defp wait_for_restart(name, previous_pid, attempts) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != previous_pid ->
        if Process.alive?(pid) do
          pid
        else
          Process.sleep(25)
          wait_for_restart(name, previous_pid, attempts - 1)
        end

      _ ->
        Process.sleep(25)
        wait_for_restart(name, previous_pid, attempts - 1)
    end
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  # A provider whose map is valid except that it never declares `storage_scheme`.
  defp stub_without_scheme do
    CapabilityStubProvider.define!(
      name: :no_scheme,
      capabilities: %{
        provider_id: :no_scheme,
        contract_version: "br.capabilities.v1",
        supports: [:claim]
      }
    )
  end
end
