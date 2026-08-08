defmodule ForemanServer.TaskProvider.RegistryRouteTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.ProviderError

  @route_ok_event [:foreman_server, :task_provider, :registry, :route, :ok]
  @route_error_event [:foreman_server, :task_provider, :registry, :route, :error]

  defmodule ContractVersionStubV999 do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :test

    @impl true
    def capabilities do
      %{
        provider_id: :test,
        contract_version: "br.capabilities.v999",
        supports: [:claim]
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def list_ready(_project_config, _opts), do: {:ok, []}

    @impl true
    def get(_id, _project_config), do: {:error, ProviderError.new("test", "unavailable")}

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

  defmodule UnavailableStub do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :unavailable_stub

    @impl true
    def capabilities do
      %{
        provider_id: :unavailable_stub,
        contract_version: "br.capabilities.v1",
        supports: [:claim]
      }
    end

    @impl true
    def available?, do: false

    @impl true
    def list_ready(_project_config, _opts), do: {:ok, []}

    @impl true
    def get(_id, _project_config), do: {:error, ProviderError.new("test", "unavailable")}

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

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: [BeadsAdapter]
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
    end)

    :ok
  end

  test "route/2 returns the module declaring the required transition" do
    assert {:ok, BeadsAdapter} = Registry.route(:claim, :beads)
  end

  test "route/2 returns {:error, :no_provider_for_transition} for unsupported transition" do
    assert {:error, :no_provider_for_transition} =
             Registry.route(:nonexistent_transition, :beads)
  end

  test "route/2 returns {:error, :no_provider_for_transition} for mismatched routing key" do
    assert {:error, :no_provider_for_transition} =
             Registry.route(:claim, :nonexistent_provider)
  end

  test "registering with contract_version outside accepted range returns {:error, :contract_version_mismatch}" do
    assert {:error, :contract_version_mismatch} = Registry.register(ContractVersionStubV999)
  end

  test "global register/1 keeps unavailable providers in the routing snapshot" do
    assert {:ok, UnavailableStub} = Registry.register(UnavailableStub)

    assert Registry.routing_snapshot() == %{
             beads: BeadsAdapter,
             unavailable_stub: UnavailableStub
           }

    assert {:ok, UnavailableStub} = Registry.route(:claim, :unavailable_stub)
  end

  test "both :claim and :reopen round-trip through route/2" do
    assert {:ok, BeadsAdapter} = Registry.route(:claim, :beads)
    assert {:ok, BeadsAdapter} = Registry.route(:reopen, :beads)
  end

  test "telemetry [:foreman_server, :task_provider, :registry, :route, :ok] fires on success" do
    handler_id = attach_handler(@route_ok_event)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, BeadsAdapter} = Registry.route(:claim, :beads)

    assert_receive {:telemetry, @route_ok_event, %{count: 1}, metadata}, 1_000
    assert metadata.transition == :claim
    assert metadata.routing_key == :beads
    assert metadata.provider == BeadsAdapter
  end

  test "telemetry [:foreman_server, :task_provider, :registry, :route, :error] fires on failure" do
    handler_id = attach_handler(@route_error_event)

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :no_provider_for_transition} = Registry.route(:claim, :nonexistent)

    assert_receive {:telemetry, @route_error_event, %{count: 1}, metadata}, 1_000
    assert metadata.transition == :claim
    assert metadata.routing_key == :nonexistent
    assert metadata.reason == :no_provider_for_transition
  end

  defp attach_handler(event) do
    handler_id = "registry-route-test-#{System.unique_integer([:positive])}"

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_telemetry/4, self())

    handler_id
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
