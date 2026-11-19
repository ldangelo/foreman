defmodule ForemanServer.TaskProvider.RegistryRouteTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.CommandGateway
  alias ForemanServer.TaskProvider.ProjectProviderProjector
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.KataAdapter
  alias ForemanServer.TaskProviders.KataRunnerMock
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.Test.Support.CapabilityStubProvider
  alias ForemanServer.Workflow.RunExecutor

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
        supports: [:claim],
        storage_scheme: :sqlite
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
    def create(_project_id, _attrs) do
      {:error, ProviderError.new("test", "unavailable")}
    end

    @impl true
    def add_dependency(_id, _depends_on_id, _project_config), do: :ok

    @impl true
    def annotate(_id, _body, _project_config), do: {:error, :not_implemented}
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
        supports: [:claim],
        storage_scheme: :sqlite
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
    def create(_project_id, _attrs) do
      {:error, ProviderError.new("test", "unavailable")}
    end

    @impl true
    def add_dependency(_id, _depends_on_id, _project_config), do: :ok

    @impl true
    def annotate(_id, _body, _project_config), do: {:error, :not_implemented}
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

  describe "per-project routing is keyed on the provider's storage scheme (TRD-KATA-T053, AC-003-2, AC-010-2)" do
    @cwd "/work/cli-project"

    test "a :cli_process project is routed by its cwd; no database_path is demanded or invented" do
      cli = scheme_stub(:cli_process)

      assert :ok = Registry.register_for_project("cli-project", cli, %{cwd: @cwd})
      assert {:ok, ^cli} = Registry.route(:claim, {"cli-project", @cwd})

      assert {:ok, %{provider_module: ^cli, config: config}} =
               Registry.project_config("cli-project")

      assert config == %{cwd: @cwd}
    end

    test "string keys from JSON ingress bind a :cli_process project the same way" do
      cli = scheme_stub(:cli_process)

      assert :ok = Registry.register_for_project("cli-json", cli, %{"cwd" => @cwd})
      assert {:ok, ^cli} = Registry.route(:claim, {"cli-json", @cwd})
    end

    test "a different cwd is :cwd_mismatch while a :sqlite project keeps :database_path_mismatch" do
      cli = scheme_stub(:cli_process)
      sqlite = scheme_stub(:sqlite)

      assert :ok = Registry.register_for_project("cli-project", cli, %{cwd: @cwd})

      assert :ok =
               Registry.register_for_project("db-project", sqlite, %{database_path: "/abs/p.db"})

      assert {:error, :cwd_mismatch} = Registry.route(:claim, {"cli-project", "/work/elsewhere"})

      assert {:error, :database_path_mismatch} =
               Registry.route(:claim, {"db-project", "/abs/other.db"})
    end

    test "the key is the scheme's: a cwd does not bind a :sqlite project and a database_path does not bind a :cli_process one" do
      cli = scheme_stub(:cli_process)
      sqlite = scheme_stub(:sqlite)

      assert :ok = Registry.register_for_project("sqlite-cwd", sqlite, %{cwd: @cwd})
      assert :ok = Registry.register_for_project("cli-db", cli, %{database_path: "/abs/p.db"})

      assert {:error, :database_path_mismatch} = Registry.route(:claim, {"sqlite-cwd", @cwd})
      assert {:error, :cwd_mismatch} = Registry.route(:claim, {"cli-db", "/abs/p.db"})
    end

    test "a real :sqlite provider is routed by its database_path exactly as before" do
      assert :ok =
               Registry.register_for_project("beads-project", BeadsAdapter, %{
                 database_path: "/abs/beads.db"
               })

      assert {:ok, BeadsAdapter} = Registry.route(:claim, {"beads-project", "/abs/beads.db"})

      assert {:error, :database_path_mismatch} =
               Registry.route(:claim, {"beads-project", "/abs/other.db"})
    end

    test "an unsupported transition and an unregistered project are scheme-independent outcomes" do
      cli = scheme_stub(:cli_process, supports: [:claim])
      assert :ok = Registry.register_for_project("cli-project", cli, %{cwd: @cwd})

      assert {:error, :no_provider_for_transition} =
               Registry.route(:close, {"cli-project", @cwd})

      assert {:error, :task_provider_not_configured} = Registry.route(:claim, {"ghost", @cwd})

      assert :ok = Registry.unregister_for_project("cli-project", :cwd_not_found)

      assert {:error, :provider_unavailable_for_project} =
               Registry.route(:claim, {"cli-project", @cwd})
    end

    test "route telemetry redacts a cwd exactly as it redacts a database_path" do
      handler_id = attach_handler(@route_ok_event)
      on_exit(fn -> :telemetry.detach(handler_id) end)

      cli = scheme_stub(:cli_process)
      assert :ok = Registry.register_for_project("cli-telemetry", cli, %{cwd: @cwd})
      assert {:ok, ^cli} = Registry.route(:claim, {"cli-telemetry", @cwd})

      assert_receive {:telemetry, @route_ok_event, %{count: 1},
                      %{provider: ^cli, routing_key: routing_key}},
                     1_000

      assert routing_key == {"cli-telemetry", "/abs/<redacted:#{String.length(@cwd)}>"}
    end
  end

  describe "the real :cli_process adapter is routed by its cwd through the real registry (TRD-KATA-T053, AC-003-2)" do
    setup :set_mox_global

    setup do
      temp_dir =
        Path.join(System.tmp_dir!(), "registry_route_cli_#{System.unique_integer([:positive])}")

      bin_dir = Path.join(temp_dir, "bin")
      workspace = Path.join(temp_dir, "workspace")
      File.mkdir_p!(bin_dir)
      File.mkdir_p!(workspace)
      File.write!(Path.join(bin_dir, "kata"), "#!/bin/sh\nexit 0\n")
      File.chmod!(Path.join(bin_dir, "kata"), 0o755)

      original_path = System.get_env("PATH") || ""
      System.put_env("PATH", bin_dir <> ":" <> original_path)

      on_exit(fn ->
        System.put_env("PATH", original_path)
        File.rm_rf!(temp_dir)
      end)

      # `available?/0` probes `kata --version` through the runner.
      stub(KataRunnerMock, :cmd, fn ["--version"], _cwd, _opts -> {:ok, "kata v0.23.0\n"} end)

      Application.put_env(
        :foreman_server,
        :task_provider,
        actor: nil,
        accepted_contract_versions: ["br.capabilities.v1", "kata.capabilities.v1"],
        providers: [BeadsAdapter, KataAdapter]
      )

      ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

      {:ok, workspace: workspace}
    end

    test "a project registered with only a cwd routes; no database_path is demanded or invented",
         %{
           workspace: workspace
         } do
      assert :ok = Registry.register_for_project("kata-direct", KataAdapter, %{cwd: workspace})

      assert {:ok, KataAdapter} = Registry.route(:claim, {"kata-direct", workspace})
      assert {:error, :cwd_mismatch} = Registry.route(:claim, {"kata-direct", "/work/elsewhere"})

      assert {:ok, %{config: config}} = Registry.project_config("kata-direct")
      refute Map.has_key?(config, :database_path)
    end

    test "a ProjectRegistered event as the CLI sends it (short provider name, string keys) is preflighted and routed",
         %{workspace: workspace} do
      assert :ok =
               ProjectProviderProjector.process_event(%{
                 event_type: "ProjectRegistered",
                 payload: %{
                   project_id: "kata-event",
                   path: workspace,
                   task_provider: %{"provider" => "kata", "config" => %{"cwd" => workspace}}
                 }
               })

      assert {:ok, KataAdapter} = Registry.route(:claim, {"kata-event", workspace})
    end

    test "the same event for a workspace that is not there leaves the project unroutable, naming why",
         %{workspace: workspace} do
      missing = Path.join(workspace, "not-created")

      assert :ok =
               ProjectProviderProjector.process_event(%{
                 event_type: "ProjectRegistered",
                 payload: %{
                   project_id: "kata-missing",
                   path: missing,
                   task_provider: %{"provider" => "kata", "config" => %{"cwd" => missing}}
                 }
               })

      assert {:unavailable, :cwd_not_found} = :sys.get_state(Registry).per_project["kata-missing"]

      assert {:error, :provider_unavailable_for_project} =
               Registry.route(:claim, {"kata-missing", missing})
    end
  end

  describe "RunExecutor routes through the real registry by the provider's storage scheme (TRD-KATA-T053, AC-003-2)" do
    test "claim, complete and fail resolve a :cli_process project by its cwd and hand the provider that config" do
      cwd = Path.expand(System.tmp_dir!())
      project_id = unique_project_id("cli")
      cli = scheme_stub(:cli_process, supports: [:claim, :close, :reopen])

      assert :ok = Registry.register_for_project(project_id, cli, %{cwd: cwd})
      # The projection keeps the JSON-ingress string key; the registry holds the atom key.
      seed_project!(project_id, %{"cwd" => cwd})

      assert :ok = RunExecutor.claim(project_id, "task-1", "actor", "run-1")
      assert_received {:claim, "task-1", "actor", %{"cwd" => ^cwd, run_id: "run-1"}}

      assert :ok = RunExecutor.complete(project_id, "task-1", "run-1", nil)
      assert_received {:complete, "task-1", %{run_id: "run-1"}, %{"cwd" => ^cwd}}

      assert :ok = RunExecutor.fail(project_id, "task-1", "run-1", %{reason: "boom"})
      assert_received {:fail, "task-1", %{run_id: "run-1"}, %{"cwd" => ^cwd}}
    end

    test "a :cli_process project bound to another cwd is :cwd_mismatch; one without a cwd is not configured" do
      cli = scheme_stub(:cli_process)
      bound = unique_project_id("bound")
      unbound = unique_project_id("unbound")

      assert :ok = Registry.register_for_project(bound, cli, %{cwd: "/work/registered"})
      seed_project!(bound, %{"cwd" => "/work/stored-elsewhere"})

      assert :ok = Registry.register_for_project(unbound, cli, %{cwd: "/work/registered"})
      seed_project!(unbound, %{})

      assert {:error, :cwd_mismatch} = RunExecutor.claim(bound, "task-1", "actor", "run-1")

      assert {:error, :task_provider_not_configured} =
               RunExecutor.claim(unbound, "task-1", "actor", "run-1")

      refute_received {:claim, _, _, _}
    end

    test "a :sqlite project is still resolved by its database_path" do
      sqlite = scheme_stub(:sqlite)
      project_id = unique_project_id("sqlite")
      database_path = "/abs/#{project_id}.db"

      assert :ok =
               Registry.register_for_project(project_id, sqlite, %{
                 "database_path" => database_path
               })

      seed_project!(project_id, %{"database_path" => database_path})

      assert :ok = RunExecutor.claim(project_id, "task-1", "actor", "run-1")
      assert_received {:claim, "task-1", "actor", %{"database_path" => ^database_path}}

      other = unique_project_id("sqlite-other")
      assert :ok = Registry.register_for_project(other, sqlite, %{"database_path" => "/abs/a.db"})
      seed_project!(other, %{"database_path" => "/abs/b.db"})

      assert {:error, :database_path_mismatch} =
               RunExecutor.claim(other, "task-1", "actor", "run-1")
    end

    test "a project the registry does not know is reported before its config is judged" do
      project_id = unique_project_id("ghost")
      seed_project!(project_id, %{"cwd" => "/work/ghost"})

      assert {:error, :task_provider_not_configured} =
               RunExecutor.claim(project_id, "task-1", "actor", "run-1")
    end
  end

  defp attach_handler(event) do
    handler_id = "registry-route-test-#{System.unique_integer([:positive])}"

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_telemetry/4, self())

    handler_id
  end

  # A provider of the given storage scheme; `supports` defaults to `[:claim]`.
  defp scheme_stub(scheme, opts \\ []) do
    CapabilityStubProvider.define!(
      name: :"#{scheme}_stub",
      capabilities: %{
        provider_id: :"#{scheme}_stub",
        contract_version: "br.capabilities.v1",
        supports: Keyword.get(opts, :supports, [:claim]),
        storage_scheme: scheme
      }
    )
  end

  # The event log outlives the VM, so a literal id would be `already_exists` on the next run.
  defp unique_project_id(label), do: "proj-#{label}-#{Elixir.EventStore.UUID.uuid4()}"

  # `RunExecutor` reads the project's provider config from the projection, not the registry.
  defp seed_project!(project_id, config) do
    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: "project.register:#{project_id}",
               aggregate_id: "project:#{project_id}",
               type: "project.register",
               payload: %{
                 project_id: project_id,
                 name: "RegistryRouteTest #{project_id}",
                 path: System.tmp_dir!(),
                 task_provider: %{provider: "stub", config: config}
               }
             })
  end

  def handle_telemetry(event, measurements, metadata, pid) do
    send(pid, {:telemetry, event, measurements, metadata})
  end
end
