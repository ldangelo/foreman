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
      %{provider_id: :compatible, contract_version: "br.capabilities.v1"}
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
      %{provider_id: :incompatible, contract_version: "br.capabilities.v2"}
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
      %{provider_id: :concurrent, contract_version: "br.capabilities.v1"}
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
      %{provider_id: :unavailable, contract_version: "br.capabilities.v1"}
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
             accepted_versions: ["br.capabilities.v1"]
           }
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

    start_supervised!(Registry)

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

  test "available?/0 filtering removes unavailable providers" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    start_supervised!(Registry)

    assert {:error, :unavailable} = Registry.register(UnavailableProvider)
    refute Map.has_key?(Registry.routing_snapshot(), :unavailable)
  end

  test "restart-redundancy re-registers config providers" do
    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: [ForemanServer.TaskProviders.BeadsAdapter]
    )

    pid = start_supervised!(Registry)

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

    pid = start_supervised!(Registry)

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
