defmodule ForemanServer.TaskProvider.RegistryTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProvider.Registry

  @restart_event [:foreman_server, :task_provider, :registry, :restarted]

  defmodule CompatibleProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :compatible

    @impl true
    def capabilities do
      %{provider_id: :compatible, contract_version: "br.capabilities.v1", supports: [:claim]}
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
  end

  defmodule IncompatibleProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :incompatible

    @impl true
    def capabilities do
      %{provider_id: :incompatible, contract_version: "br.capabilities.v2", supports: [:claim]}
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
  end

  defmodule ConcurrentProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :concurrent

    @impl true
    def capabilities do
      %{provider_id: :concurrent, contract_version: "br.capabilities.v1", supports: [:claim]}
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
  end

  defmodule UnavailableProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :unavailable

    @impl true
    def capabilities do
      %{provider_id: :unavailable, contract_version: "br.capabilities.v1", supports: [:claim]}
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

    refute_receive {:telemetry, @restart_event, _, _}, 50

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

    refute_receive {:telemetry, @restart_event, _, _}, 50

    :ok = :sys.terminate(pid, :kill)
    wait_for_restart(Registry, pid)

    assert_receive {:telemetry, @restart_event, %{count: 1}, metadata}, 1_000
    assert metadata.registry == Registry
    assert metadata.providers == [:beads]
    assert metadata.restart_count == 1
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
end
