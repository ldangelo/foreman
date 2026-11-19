defmodule ForemanServer.TaskProvider.RegistryRoutingTest do
  @moduledoc """
  `KataAdapter` beside `BeadsAdapter` in the real `TaskProvider.Registry` (TRD-KATA-T045, REQ-003).

  The registry is the real GenServer; the two adapters are the real modules, their subprocess
  boundaries (`br`, `kata`) the Mox mocks. AC-003-4 is driven through the same command path an
  operator uses: `CommandGateway.dispatch_operator` -> `Project` aggregate -> `ProjectUpdated`
  -> `ProjectProviderProjector` -> `Registry` -> `RunExecutor`.
  """
  use ExUnit.Case, async: false

  import ForemanServer.TestSupport.AdoptionFixtures, only: [seed_run!: 1, uid: 0]
  import Mox

  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.TaskProvider.ProjectProviderProjector
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.BeadsAdapter
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.KataAdapter
  alias ForemanServer.TaskProviders.KataRunnerMock
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.Workflow.RunExecutor

  setup :set_mox_global

  # A task ref both providers accept (Kata's is `^[a-z0-9]+$`).
  @issue_ref "abc4"

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])
    original_path = System.get_env("PATH") || ""

    temp_dir =
      Path.join(System.tmp_dir!(), "registry_routing_#{System.unique_integer([:positive])}")

    bin_dir = Path.join(temp_dir, "bin")
    workspace = Path.join(temp_dir, "workspace")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(workspace)
    File.write!(Path.join(bin_dir, "kata"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(bin_dir, "kata"), 0o755)

    # `KataAdapter.available?/0` needs `kata` on PATH and `kata --version` to exit zero.
    System.put_env("PATH", bin_dir <> ":" <> original_path)
    stub(KataRunnerMock, :cmd, fn ["--version"], _cwd, _opts -> {:ok, "kata v0.23.0\n"} end)

    # Beads' own preflight (`br where --db <path>`) must pass for the projector to register.
    stub(BrRunnerMock, :cmd, fn {:where, %{database_path: _}}, _config, _opts -> {:ok, %{}} end)

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1", "kata.capabilities.v1"],
      providers: [BeadsAdapter, KataAdapter]
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(Registry)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
      System.put_env("PATH", original_path)
      File.rm_rf!(temp_dir)
    end)

    {:ok, workspace: workspace}
  end

  describe "both adapters are registered side by side" do
    test "KataAdapter and BeadsAdapter are in routing_snapshot/0 under their provider ids" do
      snapshot = Registry.routing_snapshot()

      assert snapshot[:kata] == KataAdapter
      assert snapshot[:beads] == BeadsAdapter
    end

    test "their supports overlap and each transition routes to the provider that declares it" do
      shared = overlap(BeadsAdapter, KataAdapter)

      assert Enum.sort(shared) ==
               Enum.sort(
                 [:claim, :close, :reopen, :annotate, :set_priority, :set_assignee] ++
                   [:list_dependencies, :add_dependency, :remove_dependency, :create]
               )

      # The global routing key is the provider's `name/0` (`:beads` and `"kata"`).
      for transition <- shared do
        assert {:ok, BeadsAdapter} = Registry.route(transition, BeadsAdapter.name()),
               inspect(transition)

        assert {:ok, KataAdapter} = Registry.route(transition, KataAdapter.name()),
               inspect(transition)
      end
    end

    test "a transition only one of them supports routes to that one alone" do
      assert {:ok, BeadsAdapter} = Registry.route(:label, BeadsAdapter.name())
      assert {:error, :no_provider_for_transition} = Registry.route(:label, KataAdapter.name())
    end
  end

  describe "per-project provider config routes each project to its own provider (REQ-003)" do
    test "a beads project is routed by its database_path, a kata project by its cwd", %{
      workspace: workspace
    } do
      assert :ok =
               Registry.register_for_project("beads-project", BeadsAdapter, %{
                 database_path: "/abs/beads.db"
               })

      assert :ok = Registry.register_for_project("kata-project", KataAdapter, %{cwd: workspace})

      assert {:ok, BeadsAdapter} = Registry.route(:claim, {"beads-project", "/abs/beads.db"})
      assert {:ok, KataAdapter} = Registry.route(:claim, {"kata-project", workspace})
    end

    test "one project's binding never routes another project's provider", %{workspace: workspace} do
      assert :ok =
               Registry.register_for_project("beads-project", BeadsAdapter, %{
                 database_path: "/abs/beads.db"
               })

      assert :ok = Registry.register_for_project("kata-project", KataAdapter, %{cwd: workspace})

      assert {:error, :database_path_mismatch} =
               Registry.route(:claim, {"beads-project", "/abs/other.db"})

      assert {:error, :cwd_mismatch} = Registry.route(:claim, {"kata-project", "/work/elsewhere"})
      assert {:error, :cwd_mismatch} = Registry.route(:claim, {"kata-project", "/abs/beads.db"})
    end

    test "a project is routed to the provider of its own config, whatever the other projects use",
         %{workspace: workspace} do
      assert :ok = Registry.register_for_project("kata-project", KataAdapter, %{cwd: workspace})

      assert :ok =
               Registry.register_for_project("beads-project", BeadsAdapter, %{
                 database_path: "/abs/beads.db"
               })

      assert {:ok, %{provider_module: KataAdapter, config: %{cwd: ^workspace}}} =
               Registry.project_config("kata-project")

      assert {:ok, %{provider_module: BeadsAdapter, config: %{database_path: "/abs/beads.db"}}} =
               Registry.project_config("beads-project")
    end
  end

  # PRD AC-003-4: the provider choice is data on the project, not a fork in the dispatch path.
  describe "AC-003-4: a project switches beads -> kata -> beads without losing run history" do
    test "the project, its routing and its runs follow only the stored provider block", %{
      workspace: workspace
    } do
      id = uid()
      project_id = "switch-#{id}"
      database_path = Path.join(workspace, ".beads/beads.db")
      run_id = "run-#{id}"
      task_id = "task-#{id}"
      test_pid = self()

      # What each provider's subprocess boundary saw, tagged with the provider that ran it.
      stub(BrRunnerMock, :cmd, fn
        {:where, %{database_path: _}}, _config, _opts ->
          {:ok, %{}}

        request, config, _opts ->
          send(test_pid, {:br, request, config})
          {:error, %{stdout: "", stderr: "br refused", exit_status: 1}}
      end)

      stub(KataRunnerMock, :cmd, fn
        ["--version"], _cwd, _opts ->
          {:ok, "kata v0.23.0\n"}

        argv, cwd, _opts ->
          send(test_pid, {:kata, argv, cwd})

          {:error,
           ProviderError.new("KATA_REFUSED", "kata refused",
             context: %{exit_code: 1, stderr_byte_count: 7}
           )}
      end)

      # 1. Registered on beads.
      assert {:ok, registered} =
               dispatch(project_id, "project.register", %{
                 "project_id" => project_id,
                 "path" => workspace,
                 "task_provider" => %{
                   "provider" => "beads",
                   "config" => %{"database_path" => database_path}
                 }
               })

      project!(registered)
      assert {:ok, BeadsAdapter} = Registry.route(:claim, {project_id, database_path})

      # The project accumulates run history while it is on beads.
      seed_run!(%{
        project: project_id,
        run: run_id,
        task: task_id,
        repo: workspace,
        terminal?: true
      })

      assert run_ids(project_id) == [run_id]

      assert {:error, _beads_refused} =
               RunExecutor.claim(project_id, @issue_ref, "actor", "run-b1")

      assert_received {:br, _request, %{"database_path" => ^database_path}}
      refute_received {:kata, _argv, _cwd}

      # 2. Switched to kata through the operator command path: the cwd rides in the update.
      assert {:ok, to_kata} =
               dispatch(project_id, "project.update", %{
                 "project_id" => project_id,
                 "task_provider" => %{"provider" => "kata", "config" => %{"cwd" => workspace}}
               })

      project!(to_kata)

      assert %{task_provider: %{"provider" => "kata", "config" => %{"cwd" => ^workspace}}} =
               ProjectionStore.project_projection(project_id)

      assert {:ok, KataAdapter} = Registry.route(:claim, {project_id, workspace})
      assert {:error, _stale_binding} = Registry.route(:claim, {project_id, database_path})
      assert run_ids(project_id) == [run_id]

      # The very same dispatch call now reaches Kata and not Beads.
      assert {:error, _kata_refused} =
               RunExecutor.claim(project_id, @issue_ref, "actor", "run-k1")

      assert_received {:kata, ["claim", @issue_ref | _], ^workspace}
      refute_received {:br, _request, _config}

      # 3. Switched back: beads carries its database_path again.
      assert {:ok, to_beads} =
               dispatch(project_id, "project.update", %{
                 "project_id" => project_id,
                 "task_provider" => %{
                   "provider" => "beads",
                   "config" => %{"database_path" => database_path}
                 }
               })

      project!(to_beads)

      assert %{
               task_provider: %{
                 "provider" => "beads",
                 "config" => %{"database_path" => ^database_path}
               }
             } =
               ProjectionStore.project_projection(project_id)

      assert {:ok, BeadsAdapter} = Registry.route(:claim, {project_id, database_path})
      assert {:error, _stale_binding} = Registry.route(:claim, {project_id, workspace})

      assert {:error, _beads_refused} =
               RunExecutor.claim(project_id, @issue_ref, "actor", "run-b2")

      assert_received {:br, _request, %{"database_path" => ^database_path}}
      refute_received {:kata, _argv, _cwd}

      # The run recorded before the first switch is still the project's, untouched.
      assert run_ids(project_id) == [run_id]
      assert %{project_id: ^project_id, run_id: ^run_id} = ProjectionStore.run(run_id)
    end

    test "a switch that omits the target scheme's key is refused and leaves routing and history",
         %{workspace: workspace} do
      id = uid()
      project_id = "refused-#{id}"
      run_id = "run-#{id}"

      assert {:ok, registered} =
               dispatch(project_id, "project.register", %{
                 "project_id" => project_id,
                 "path" => workspace,
                 "task_provider" => %{"provider" => "kata", "config" => %{"cwd" => workspace}}
               })

      project!(registered)

      seed_run!(%{
        project: project_id,
        run: run_id,
        task: "task-#{id}",
        repo: workspace,
        terminal?: true
      })

      assert {:error, {:missing_or_invalid, :database_path}} =
               dispatch(project_id, "project.update", %{
                 "project_id" => project_id,
                 "task_provider" => %{"provider" => "beads"}
               })

      assert {:ok, KataAdapter} = Registry.route(:claim, {project_id, workspace})
      assert run_ids(project_id) == [run_id]
    end
  end

  # Operator command path: string-keyed JSON body, as `CommandController` hands the gateway.
  defp dispatch(project_id, type, payload) do
    CommandGateway.dispatch_operator(%{
      type: type,
      command_id: "#{type}:#{project_id}:#{System.unique_integer([:positive])}",
      aggregate_id: "project:#{project_id}",
      payload: payload
    })
  end

  # The projector consumes the event the aggregate emitted, as it does from the live broadcast.
  defp project!(%{"event_type" => _} = event) do
    assert :ok = ProjectProviderProjector.process_event(event)
  end

  defp run_ids(project_id) do
    [project_id: project_id]
    |> ProjectionStore.list_runs()
    |> Enum.map(& &1.run_id)
    |> Enum.sort()
  end

  defp overlap(first, second) do
    first_supports = MapSet.new(first.capabilities().supports)

    second.capabilities().supports
    |> Enum.filter(&MapSet.member?(first_supports, &1))
  end
end
