defmodule ForemanServer.Workflow.RunExecutorIsolationTest do
  @moduledoc """
  TRD-019 / PRD AC-006-2: the host workflow door cannot enforce a project's
  `environment.network` policy, so a run whose project requires one is refused at
  kickoff, before the task claim, the worktree and any phase. A project with the
  default policy proceeds.

  Real RunExecutors started through `RunAdmission`; the task provider is the
  recording `FakeTaskProvider`, so "no claim" is the provider's own call log.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.{CommandGateway, EventStore, Identity, ProjectEnvironment, ProjectionStore}
  alias ForemanServer.Jobsite.{ExecutionProfile, NetworkPolicy}
  alias ForemanServer.RunAdmission
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TestSupport.{FakeTaskProvider, KeyStoreReset, TestApplication}
  alias ForemanServer.Workflow.{RunExecutor, RunWorktreeLayout}

  @actor "foreman-runner"
  @refusal_tuple "{:isolation_unsupported, :network, :host_workflow}"

  defmodule Worker do
    @moduledoc false
    use GenServer

    alias ForemanServer.Overwatch.WorkerProtocol

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_info({:overwatch_activate, _worker_id, _run_id, parent}, state) do
      send(parent, {:overwatch_activated, self()})
      send(self(), :run)
      {:noreply, state}
    end

    def handle_info(:run, state) do
      _ =
        WorkerProtocol.emit(:worker_exited, %{
          worker_id: Keyword.fetch!(state, :worker_id),
          run_id: Keyword.fetch!(state, :run_id)
        })

      case Keyword.get(state, :result_recipient) do
        pid when is_pid(pid) -> send(pid, {:worker_result, {:ok, "artifact"}})
        _ -> :ok
      end

      {:stop, :normal, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  defmodule BackendAdapter do
    @moduledoc false
    @behaviour ForemanServer.AgentRuntime.BackendAdapter

    @impl true
    def name, do: :pi

    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [:workflow_execution],
        weaknesses: [:none],
        supported_contexts: [:implement, :test]
      }

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "artifact", %{}}
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)

    ensure_started(
      {Elixir.Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
      ForemanServer.RunExecutorRegistry
    )

    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)

    ensure_started(
      ForemanServer.AgentRuntime.AdapterCatalog,
      ForemanServer.AgentRuntime.AdapterCatalog
    )

    ensure_started(
      ForemanServer.AgentRuntime.InvocationSupervisor,
      ForemanServer.AgentRuntime.InvocationSupervisor
    )

    ensure_started(ForemanServer.TaskProvider.Registry, ForemanServer.TaskProvider.Registry)
    ensure_started(ForemanServer.Agents.JidoShellRunner, ForemanServer.Agents.JidoShellRunner)
    ensure_started(ForemanServer.Overwatch, ForemanServer.Overwatch)

    previous = ForemanServer.AgentRuntime.AdapterCatalog.routing_snapshot()

    for %{adapter: module} <- previous do
      _ = ForemanServer.AgentRuntime.AdapterCatalog.unregister(module)
    end

    {:ok, _} = ForemanServer.AgentRuntime.register_adapter(BackendAdapter)

    on_exit(fn ->
      _ = ForemanServer.AgentRuntime.AdapterCatalog.unregister(BackendAdapter)

      for %{adapter: module} <- previous do
        _ = ForemanServer.AgentRuntime.register_adapter(module)
      end
    end)

    :ok
  end

  setup do
    previous_provider = Application.get_env(:foreman_server, :task_provider, [])
    previous_worker = Application.get_env(:foreman_server, :worker_adapter)

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: @actor,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    Application.put_env(:foreman_server, :worker_adapter, Worker)

    ForemanServer.TestSupport.RunSlotsReset.reset!()
    TestApplication.reset_application_child!(Registry)

    dispatcher = Process.whereis(ForemanServer.Workflow.Dispatcher)

    if dispatcher do
      :sys.suspend(dispatcher)
      on_exit(fn -> ForemanServer.TestSupport.DispatcherRestart.restart!() end)
    end

    KeyStoreReset.reset!()
    start_supervised!(FakeTaskProvider)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_provider)

      case previous_worker do
        nil -> Application.delete_env(:foreman_server, :worker_adapter)
        adapter -> Application.put_env(:foreman_server, :worker_adapter, adapter)
      end

      KeyStoreReset.reset!()
    end)

    :ok
  end

  for {mode, hosts} <- [{"none", []}, {"allowlist", ["example.com"]}] do
    test "a #{mode} policy on the host door ends the run before the claim, the worktree and any phase" do
      w = world("refuse-#{unquote(mode)}", %{mode: unquote(mode), hosts: unquote(hosts)})
      start_executor!(w)

      assert_refused!(w)
    end
  end

  describe "NetworkPolicy.check_backend/2" do
    test "an unknown mode is non-default: refused on the host, never read as the default" do
      assert {:error, {:isolation_unsupported, :network, :host_workflow}} ==
               NetworkPolicy.check_backend(
                 %{"mode" => "mystery"},
                 ExecutionProfile.host_backend()
               )
    end

    test "an absent or default policy is accepted on the host" do
      assert :ok == NetworkPolicy.check_backend(nil, ExecutionProfile.host_backend())

      assert :ok ==
               NetworkPolicy.check_backend(
                 %{"mode" => "default"},
                 ExecutionProfile.host_backend()
               )
    end

    test "the docker jobsite, which enforces the policy, is not refused" do
      assert :ok ==
               NetworkPolicy.check_backend(
                 %{"mode" => "allowlist", "hosts" => []},
                 ExecutionProfile.docker_backend()
               )
    end
  end

  test "a resumed run is refused the same way, before any recovery is recorded" do
    w = world("refuse-resume", %{mode: "allowlist", hosts: ["example.com"]})
    start_executor!(w, resume_from: 0)

    assert_refused!(w)
    refute Enum.any?(events(w.run_id), &match?({"RunRecoveryAttempted", _}, &1))
  end

  test "the default policy proceeds: the task is claimed and the phase starts" do
    w = world("proceed-default", nil, false)
    start_executor!(w)

    await(fn ->
      if status(w.run_id) == "completed", do: {:ok, :completed}, else: :waiting
    end)

    assert {:claim, w.task_id} in FakeTaskProvider.calls(w.db)
    assert [%{status: "completed"}] = ProjectionStore.phases_for_run(w.run_id)
  end

  test "a project with no policy at all proceeds" do
    w = world("proceed-absent", nil, false)

    assert ProjectEnvironment.environment(w.project_id)["network"] ==
             %{"mode" => "default", "hosts" => []}

    start_executor!(w)

    await(fn ->
      if status(w.run_id) == "completed", do: {:ok, :completed}, else: :waiting
    end)

    assert {:claim, w.task_id} in FakeTaskProvider.calls(w.db)
  end

  # What a refused run looks like: failed and terminal on the run and task read
  # models with the typed reason, no claim, no worktree, not one phase.
  defp assert_refused!(w) do
    # Bounded wait that fails FAST and by name if a phase starts: a refusal that
    # let the run through must read as a started phase, not as a timeout.
    run =
      await(
        fn ->
          case ProjectionStore.phases_for_run(w.run_id) do
            [] -> :ok
            phases -> flunk("the run was not refused: a phase started #{inspect(phases)}")
          end

          case ProjectionStore.run(w.run_id) do
            %{status: "failed", terminal?: true} = run -> {:ok, run}
            _ -> :waiting
          end
        end,
        5_000
      )

    for reason <- [run.failure_reason, ProjectionStore.task_projection(w.task_id).failure_reason] do
      assert reason =~ @refusal_tuple
      assert reason =~ "environment.network"
      assert reason =~ "docker jobsite"
    end

    assert FakeTaskProvider.calls(w.db) == []
    assert FakeTaskProvider.status(w.db, w.task_id) == "open"

    assert ProjectionStore.phases_for_run(w.run_id) == []

    assert {:error, :stream_not_found} =
             EventStore.read_stream_forward(
               "phase:#{w.run_id}:#{Identity.phase_id(w.run_id, 1)}",
               0,
               99
             )

    refute File.exists?(RunWorktreeLayout.run_root(w.project_id, w.task_id, w.run_id))

    await(fn ->
      if RunExecutor.pid_for(w.run_id) == nil, do: {:ok, :stopped}, else: :waiting
    end)
  end

  # A project (a real git repository, so a worktree could be made), its
  # `environment.network` policy, and an admitted run. `worktree?: false`
  # lets the proceeding runs skip the checkout; the refused ones keep the
  # default-on worktree, so "no worktree" is a real absence.
  defp world(label, network, worktree? \\ true) do
    project_id = "project-#{label}-#{System.unique_integer([:positive])}"
    db = "/abs/isolation/#{project_id}.db"
    repo = init_repo!(project_id)
    register_project!(project_id, db, repo)

    if network do
      dispatch_system!("project.environment.set", "project:#{project_id}", %{
        project_id: project_id,
        network: network
      })

      await(fn ->
        case ProjectEnvironment.environment(project_id)["network"]["mode"] do
          mode when mode == network.mode -> {:ok, mode}
          other -> {:waiting, other}
        end
      end)
    end

    task_id = "task-#{label}-#{System.unique_integer([:positive])}"
    run_id = "run-#{label}-#{System.unique_integer([:positive])}"
    approval_id = "approval-#{run_id}"
    FakeTaskProvider.put_issue(db, task_id, "open")

    artifact_dir = Path.join(System.tmp_dir!(), "isolation-#{run_id}")
    File.mkdir_p!(artifact_dir)
    on_exit(fn -> File.rm_rf(artifact_dir) end)

    snapshot =
      %{
        phases: [
          %{
            name: :implement,
            artifact_template: %{path: Path.join([artifact_dir, "{run_id}-{task_id}.md"])},
            context: %{"script_key" => run_id}
          }
        ]
      }
      |> then(&if(worktree?, do: &1, else: Map.put(&1, :worktree, %{enabled: false})))

    dispatch_system!("task.create", "task:#{task_id}", %{
      task_id: task_id,
      project_id: project_id,
      task_type: "implement",
      title: "isolation #{task_id}"
    })

    dispatch_system!("task.approve", "task:#{task_id}", %{
      task_id: task_id,
      approval_id: approval_id,
      approved_by: "isolation-test",
      approved_at: "2026-08-06T00:00:00Z",
      run_id: run_id,
      workflow_snapshot: snapshot
    })

    dispatch_system!("task.dispatch", "task:#{task_id}", %{task_id: task_id})

    assert {:ok, result} =
             RunAdmission.start(project_id, %{
               run_id: run_id,
               task_id: task_id,
               project_id: project_id,
               approval_id: approval_id,
               workflow_snapshot: snapshot,
               phase_specs: snapshot.phases
             })

    refute result in [:slot_queued, :queued, nil], "the run was not admitted: #{inspect(result)}"

    %{project_id: project_id, db: db, task_id: task_id, run_id: run_id}
  end

  defp init_repo!(project_id) do
    repo = Path.join(System.tmp_dir!(), "isolation-repo-#{project_id}")
    File.rm_rf!(repo)
    File.mkdir_p!(repo)

    for args <- [
          ["init", "--initial-branch=main", "--quiet"],
          ["config", "user.email", "t@x"],
          ["config", "user.name", "T"]
        ] do
      {_, 0} = System.cmd("git", ["-C", repo | args])
    end

    File.write!(Path.join(repo, "README.md"), "seed")
    {_, 0} = System.cmd("git", ["-C", repo, "add", "."])
    {_, 0} = System.cmd("git", ["-C", repo, "commit", "--no-gpg-sign", "-q", "-m", "seed"])

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(Path.join(RunWorktreeLayout.base_root(), project_id))
    end)

    repo
  end

  defp register_project!(project_id, db, repo) do
    dispatch_system!("project.register", "project:#{project_id}", %{
      project_id: project_id,
      name: project_id,
      path: repo,
      task_provider: %{
        provider: FakeTaskProvider.provider_ref(),
        config: %{"database_path" => db}
      }
    })

    assert :ok =
             Registry.register_for_project(project_id, FakeTaskProvider, %{"database_path" => db})

    await(fn ->
      case ProjectionStore.project_projection(project_id) do
        %{} -> {:ok, :registered}
        other -> {:waiting, other}
      end
    end)
  end

  defp start_executor!(%{run_id: run_id, task_id: task_id}, opts \\ []) do
    task = ProjectionStore.task_projection(task_id)

    start_supervised!(%{
      id: {RunExecutor, run_id},
      start: {RunExecutor, :start_link, [run_id, task, opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    })
  end

  defp dispatch_system!(type, aggregate_id, payload) do
    command_id = "#{type}:#{aggregate_id}:#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: command_id,
               aggregate_id: aggregate_id,
               type: type,
               payload: payload
             })
  end

  defp events(run_id) do
    {:ok, recorded} = EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
    for e <- recorded, do: {Aggregate.event_type(e), Aggregate.event_payload(e)}
  end

  defp status(run_id), do: Aggregate.load(Run, "run:#{run_id}") |> elem(0) |> Map.fetch!(:status)

  defp await(fun, timeout_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      other ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("timed out waiting (last: #{inspect(other)})")
        else
          Process.sleep(25)
          do_await(fun, deadline)
        end
    end
  end

  defp ensure_started(child_spec, name) do
    if Process.whereis(name) == nil, do: start_supervised!(child_spec)
    :ok
  end
end
