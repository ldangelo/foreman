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

  setup_all do
    {:ok, _telemetry_apps} = Application.ensure_all_started(:telemetry)
    :ok
  end

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
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

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
