defmodule ForemanServer.TaskProvider.ProjectProviderProjectorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProvider.ProjectProviderProjector
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.ProviderError

  @unregister_event [:foreman_server, :task_provider, :registry, :unregister_for_project]

  defmodule ConfiguredProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :configured_provider

    @impl true
    def capabilities do
      %{
        provider_id: :configured_provider,
        contract_version: "br.capabilities.v1",
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

    def preflight_database(_database_path, _opts), do: :ok
  end

  defmodule UpdatedProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :updated_provider

    @impl true
    def capabilities do
      %{
        provider_id: :updated_provider,
        contract_version: "br.capabilities.v1",
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

    def preflight_database(_database_path, _opts), do: :ok
  end

  defmodule MissingDatabaseProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: :missing_database_provider

    @impl true
    def capabilities do
      %{
        provider_id: :missing_database_provider,
        contract_version: "br.capabilities.v1",
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

    def preflight_database(_database_path, _opts) do
      {:error, ProviderError.new("DATABASE_NOT_FOUND", "database missing")}
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    :ok
  end

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])
    :persistent_term.erase({Registry, Registry, :boot_count})

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: [ConfiguredProvider]
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      :persistent_term.erase({Registry, Registry, :boot_count})
    end)

    :ok
  end

  test "ProjectRegistered without task_provider leaves the project unrouted" do
    assert :ok =
             ProjectProviderProjector.process_event(%{
               event_type: "ProjectRegistered",
               payload: %{project_id: "project-1", path: "/tmp/project-1", task_provider: nil}
             })

    assert {:error, :task_provider_not_configured} =
             Registry.route(:claim, {"project-1", "/tmp/project-1.db"})

    assert :sys.get_state(Registry).per_project == %{}
  end

  test "ProjectRegistered resolves provider ids through the global registry snapshot" do
    assert :ok =
             ProjectProviderProjector.process_event(%{
               event_type: "ProjectRegistered",
               payload: %{
                 project_id: "project-1",
                 path: "/tmp/project-1",
                 task_provider: %{
                   provider: :configured_provider,
                   config: %{"database_path" => "/tmp/project-1.db"}
                 }
               }
             })

    assert {:ok, ConfiguredProvider} = Registry.route(:claim, {"project-1", "/tmp/project-1.db"})
  end

  test "ProjectUpdated without task_provider preserves existing per-project routing" do
    assert :ok =
             ProjectProviderProjector.process_event(%{
               event_type: "ProjectRegistered",
               payload: %{
                 project_id: "project-1",
                 path: "/tmp/project-1",
                 task_provider: %{
                   provider: ConfiguredProvider,
                   config: %{"database_path" => "/tmp/project-1.db"}
                 }
               }
             })

    assert :ok =
             ProjectProviderProjector.process_event(%{
               event_type: "ProjectUpdated",
               payload: %{project_id: "project-1", task_provider: nil}
             })

    assert {:ok, ConfiguredProvider} = Registry.route(:claim, {"project-1", "/tmp/project-1.db"})
  end

  test "ProjectUpdated with task_provider re-registers the provider for the project" do
    assert :ok =
             ProjectProviderProjector.process_event(%{
               event_type: "ProjectRegistered",
               payload: %{
                 project_id: "project-1",
                 path: "/tmp/project-1",
                 task_provider: %{
                   provider: ConfiguredProvider,
                   config: %{"database_path" => "/tmp/project-1.db"}
                 }
               }
             })

    assert :ok =
             ProjectProviderProjector.process_event(%{
               event_type: "ProjectUpdated",
               payload: %{
                 project_id: "project-1",
                 task_provider: %{
                   provider: UpdatedProvider,
                   config: %{"database_path" => "/tmp/project-2.db"}
                 }
               }
             })

    assert {:ok, UpdatedProvider} = Registry.route(:claim, {"project-1", "/tmp/project-2.db"})

    assert {:error, :database_path_mismatch} =
             Registry.route(:claim, {"project-1", "/tmp/project-1.db"})
  end

  test "DATABASE_NOT_FOUND preflight unregisters the project and emits registry telemetry" do
    handler_id = attach_handler(@unregister_event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             ProjectProviderProjector.process_event(%{
               event_type: "ProjectRegistered",
               payload: %{
                 project_id: "project-1",
                 path: "/tmp/project-1",
                 task_provider: %{
                   provider: MissingDatabaseProvider,
                   config: %{"database_path" => "/tmp/missing.db"}
                 }
               }
             })

    assert {:error, :provider_unavailable_for_project} =
             Registry.route(:claim, {"project-1", "/tmp/missing.db"})

    assert_receive {:telemetry, @unregister_event, %{count: 1},
                    %{project_id: "project-1", reason: :database_not_found}},
                   1_000

    assert :sys.get_state(Registry).per_project == %{
             "project-1" => {:unavailable, :database_not_found}
           }
  end

  defp attach_handler(event) do
    handler_id =
      "project-provider-projector-test-#{System.unique_integer([:positive, :monotonic])}"

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_telemetry/4, self())
    handler_id
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  test "process_event accepts %EventStore.EventData{event_type:, data:} live broadcast shape" do
    assert :ok =
             ProjectProviderProjector.process_event(%EventStore.EventData{
               event_type: "ProjectRegistered",
               data: %{
                 project_id: "project-1",
                 path: "/tmp/project-1",
                 task_provider: %{
                   provider: ConfiguredProvider,
                   config: %{"database_path" => "/tmp/project-1.db"}
                 }
               }
             })

    assert {:ok, ConfiguredProvider} = Registry.route(:claim, {"project-1", "/tmp/project-1.db"})
  end

  test "process_event accepts %EventStore.RecordedEvent{event_type:, data:} replay shape" do
    assert :ok =
             ProjectProviderProjector.process_event(%EventStore.RecordedEvent{
               event_type: "ProjectRegistered",
               data: %{
                 project_id: "project-1",
                 path: "/tmp/project-1",
                 task_provider: %{
                   provider: ConfiguredProvider,
                   config: %{"database_path" => "/tmp/project-1.db"}
                 }
               }
             })

    assert {:ok, ConfiguredProvider} = Registry.route(:claim, {"project-1", "/tmp/project-1.db"})
  end

  test "rehydrate_from_projection_store/0 re-registers projects present after init" do
    fake_projects = [
      %{
        project_id: "project-existing",
        task_provider: %{
          provider: ConfiguredProvider,
          config: %{"database_path" => "/tmp/project-existing.db"}
        }
      }
    ]

    ExUnit.CaptureLog.capture_log(fn ->
      :ok = ProjectProviderProjector.rehydrate_from_projection_store(fake_projects)
    end)

    assert {:ok, ConfiguredProvider} =
             Registry.route(:claim, {"project-existing", "/tmp/project-existing.db"})
  end
end
