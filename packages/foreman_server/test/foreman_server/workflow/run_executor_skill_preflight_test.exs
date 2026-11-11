defmodule ForemanServer.Workflow.RunExecutorSkillPreflightTest do
  @moduledoc """
  TRD-022 / PRD AC-007-2: a run whose workflow `command:` names a skill the
  launching harness cannot find, or whose required harness is not installed, is
  refused at kickoff, before the task claim, the worktree and the first phase.
  An `:unverifiable` skill never blocks and is recorded on the profile of the
  phase that names it.

  Real RunExecutors started through `RunAdmission`; the task provider is the
  recording `FakeTaskProvider`, so "no claim" is the provider's own call log.
  Skill directories are temporary: the preflight reads them through the
  `:skill_home` config and the project's checkout, never the real `~/.pi`.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.{CommandGateway, EventStore, Identity, ProjectionStore}
  alias ForemanServer.Jobsite.ExecutionProfile
  alias ForemanServer.RunAdmission
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TestSupport.{FakeTaskProvider, KeyStoreReset, TestApplication, UniqueIds}
  alias ForemanServer.Workflow.{RunExecutor, RunWorktreeLayout}

  @actor "foreman-runner"

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

  # Deterministic `Jido.Harness` adapters: whether each provider reads as
  # installed is the `:installed` map of this module's app env, never the
  # machine's PATH.
  for {name, provider} <- [{:PiStub, :pi}, {:ClaudeStub, :claude}] do
    defmodule Module.concat(__MODULE__, name) do
      @moduledoc false
      @behaviour Jido.Harness.Adapter

      @provider provider

      @impl true
      def spec do
        %Jido.Harness.AdapterSpec{
          provider: @provider,
          name: "skill preflight #{@provider} stub",
          executable: Atom.to_string(@provider),
          capabilities: %Jido.Harness.Capabilities{streaming?: true, resume?: true},
          normalized_options: [],
          provider_options: []
        }
      end

      @impl true
      def status(_config) do
        installed =
          :foreman_server
          |> Application.get_env(:skill_preflight_test_installed, %{})
          |> Map.get(@provider, false)

        {:ok,
         %Jido.Harness.ProviderStatus{
           provider: @provider,
           installed: installed,
           compatible: installed
         }}
      end

      @impl true
      def run(_request, _context), do: {:error, :not_implemented}
    end
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
    previous_home = Application.get_env(:foreman_server, :skill_home)
    previous_harness = Application.get_env(:jido_harness, :providers)

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: @actor,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    Application.put_env(:foreman_server, :worker_adapter, Worker)

    # Both harnesses read as installed unless a test says otherwise; the skill
    # home is an empty temporary directory, so a skill is absent unless the test
    # puts it there.
    Application.put_env(:jido_harness, :providers, %{
      pi: __MODULE__.PiStub,
      claude: __MODULE__.ClaudeStub
    })

    install_harnesses(pi: true, claude: true)

    skill_home = Path.join(System.tmp_dir!(), "skill-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(skill_home)
    Application.put_env(:foreman_server, :skill_home, skill_home)

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
      Application.delete_env(:foreman_server, :skill_preflight_test_installed)
      File.rm_rf(skill_home)

      case previous_worker do
        nil -> Application.delete_env(:foreman_server, :worker_adapter)
        adapter -> Application.put_env(:foreman_server, :worker_adapter, adapter)
      end

      case previous_home do
        nil -> Application.delete_env(:foreman_server, :skill_home)
        home -> Application.put_env(:foreman_server, :skill_home, home)
      end

      case previous_harness do
        nil -> Application.delete_env(:jido_harness, :providers)
        providers -> Application.put_env(:jido_harness, :providers, providers)
      end

      KeyStoreReset.reset!()
    end)

    {:ok, skill_home: skill_home}
  end

  describe "a skill the harness cannot find" do
    test "ends the run before the claim, the worktree and any phase, naming phase, skill and backend" do
      w = world("missing", [command_phase(:write_prd, "/skill:no-such-skill --foreman")])
      start_executor!(w)

      run = assert_refused!(w)

      assert_failure!(run.failure_reason, :skill_not_found,
        phase: :write_prd,
        provider: :pi,
        skill: "no-such-skill",
        backend: ExecutionProfile.host_backend()
      )

      # Its own reason tuple: the provider/model one would misname the contents.
      refute run.failure_reason =~ "provider_model_preflight_failed"

      task_reason = ProjectionStore.task_projection(w.task_id).failure_reason
      assert task_reason =~ "capability_preflight_failed"
      assert task_reason =~ "class: :skill_not_found"
    end

    test "every missing skill of the run is named in the one refusal" do
      w =
        world("several", [
          command_phase(:first, "/skill:ghost-one"),
          command_phase(:second, "/skill:ghost-two")
        ])

      start_executor!(w)

      run = assert_refused!(w)
      assert run.failure_reason =~ ~s(skill: "ghost-one")
      assert run.failure_reason =~ ~s(skill: "ghost-two")
      assert run.failure_reason =~ "phase: :first"
      assert run.failure_reason =~ "phase: :second"
    end

    test "a resumed run that has completed no phase is refused the same way" do
      w = world("resume", [command_phase(:write_prd, "/skill:ghost-resume")])
      start_executor!(w, resume_from: 0)

      run = assert_refused!(w)
      assert run.failure_reason =~ "capability_preflight_failed"
      refute Enum.any?(events(w.run_id), &match?({"RunRecoveryAttempted", _}, &1))
    end
  end

  describe "a skill the harness can find" do
    test "in the home skill directory: the run is claimed and the phase carries the available verdict",
         %{skill_home: home} do
      install_skill!(home, "present-skill")
      w = world("available-home", [command_phase(:write_prd, "/skill:present-skill")], false)
      start_executor!(w)

      await_completed!(w)
      assert {:claim, w.task_id} in FakeTaskProvider.calls(w.db)

      assert [%{execution_profile: %{skill: %{state: "available"}}}] =
               ProjectionStore.phases_for_run(w.run_id)
    end

    test "under the project's .pi/agent/skills is not where pi looks: the skill is missing" do
      # pi's project skill directory is `<project>/.pi/skills`; `.pi/agent/skills`
      # is the USER agent directory's layout and only counts under the home.
      w = world("wrong-project-dir", [command_phase(:write_prd, "/skill:wrong-dir-skill")])
      install_skill!(w.repo, "wrong-dir-skill")
      start_executor!(w)

      assert_refused!(w)
    end

    test "a phase naming no skill is not touched by the skill preflight" do
      w = world("no-skill", [command_phase(:plain, "echo not-a-skill")], false)
      start_executor!(w)

      await_completed!(w)
      assert [%{execution_profile: profile}] = ProjectionStore.phases_for_run(w.run_id)
      refute Map.has_key?(profile, :skill)
    end
  end

  describe "a skill the harness cannot be asked about" do
    test "never blocks; only the phase that names it carries the unverifiable verdict" do
      w =
        world(
          "unverifiable",
          [
            command_phase(:plain_phase, "echo plain"),
            command_phase(:skill_phase, "/skill:claude-skill", provider: :claude)
          ],
          false
        )

      start_executor!(w)

      await_completed!(w)
      assert {:claim, w.task_id} in FakeTaskProvider.calls(w.db)

      by_name = w.run_id |> ProjectionStore.phases_for_run() |> Map.new(&{to_string(&1.name), &1})

      assert %{state: "unverifiable", reason: reason} =
               by_name["skill_phase"].execution_profile.skill

      assert is_binary(reason) and reason != ""
      assert by_name["skill_phase"].execution_profile.backend == "host_workflow"
      refute Map.has_key?(by_name["plain_phase"].execution_profile, :skill)
    end

    test "a skill found only in the project's own skill directory is unverifiable, not available" do
      w = world("project-only", [command_phase(:write_prd, "/skill:project-only-skill")], false)
      install_project_skill!(w.repo, "project-only-skill")
      start_executor!(w)

      # pi decides project trust at run time, for a worktree that does not exist
      # at admission: the preflight can neither refuse nor promise the skill.
      await_completed!(w)
      assert {:claim, w.task_id} in FakeTaskProvider.calls(w.db)

      assert [%{execution_profile: %{skill: %{state: "unverifiable"}}}] =
               ProjectionStore.phases_for_run(w.run_id)
    end

    test "is logged once per unverifiable phase, with the run, phase, skill, provider and backend" do
      w =
        world(
          "unverifiable-log",
          [
            command_phase(:first, "/skill:claude-one", provider: :claude),
            command_phase(:second, "/skill:claude-two", provider: :claude),
            command_phase(:third, "echo plain")
          ],
          false
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          start_executor!(w)
          await_completed!(w)
        end)

      warnings = for line <- String.split(log, "\n"), line =~ "could not verify skill", do: line
      assert length(warnings) == 2

      for {phase, skill} <- [{":first", "claude-one"}, {":second", "claude-two"}] do
        assert Enum.any?(warnings, fn line ->
                 line =~ w.run_id and line =~ ~s(skill "#{skill}") and
                   line =~ "phase #{phase}" and line =~ "provider :claude" and
                   line =~ ":host_workflow"
               end),
               "no warning for #{phase}/#{skill} in #{inspect(warnings)}"
      end
    end
  end

  describe "the agent directory the launch will use" do
    test "a project environment that sets PI_CODING_AGENT_DIR decides where the skill is looked up",
         %{skill_home: home} do
      # The skill is in the server user's agent dir but not in the one the
      # project's environment points pi at: the launch cannot load it.
      install_skill!(home, "launch-dir-skill")

      launch_dir =
        Path.join(System.tmp_dir!(), "launch-agent-dir-#{System.unique_integer([:positive])}")

      File.mkdir_p!(launch_dir)
      on_exit(fn -> File.rm_rf(launch_dir) end)

      w =
        world("launch-dir-missing", [command_phase(:write_prd, "/skill:launch-dir-skill")], true,
          vars: %{"PI_CODING_AGENT_DIR" => launch_dir}
        )

      start_executor!(w)
      run = assert_refused!(w)

      assert_failure!(run.failure_reason, :skill_not_found,
        skill: "launch-dir-skill",
        backend: ExecutionProfile.host_backend()
      )
    end

    test "a skill in the agent dir the project's environment names is available", %{
      skill_home: _home
    } do
      launch_dir =
        Path.join(System.tmp_dir!(), "launch-agent-dir-#{System.unique_integer([:positive])}")

      install_agent_dir_skill!(launch_dir, "only-in-launch-dir")
      on_exit(fn -> File.rm_rf(launch_dir) end)

      w =
        world("launch-dir-found", [command_phase(:write_prd, "/skill:only-in-launch-dir")], false,
          vars: %{"PI_CODING_AGENT_DIR" => launch_dir}
        )

      start_executor!(w)
      await_completed!(w)

      assert [%{execution_profile: %{skill: %{state: "available"}}}] =
               ProjectionStore.phases_for_run(w.run_id)
    end
  end

  describe "a harness that is not installed" do
    test "a phase that declares the provider and names a skill: refused with the backend and the skill" do
      install_harnesses(pi: true, claude: false)

      w =
        world("harness-declared", [
          command_phase(:write_prd, "/skill:needs-claude", provider: :claude)
        ])

      start_executor!(w)

      run = assert_refused!(w, "provider_model_preflight_failed")

      assert_failure!(run.failure_reason, :provider_not_installed,
        phase: :write_prd,
        provider: :claude,
        skill: "needs-claude",
        backend: ExecutionProfile.host_backend()
      )
    end

    test "a command phase on the default provider is refused too, with the skill it names" do
      install_harnesses(pi: false, claude: true)
      w = world("harness-default", [command_phase(:write_prd, "/skill:needs-pi")])
      start_executor!(w)

      run = assert_refused!(w, "provider_model_preflight_failed")

      assert_failure!(run.failure_reason, :provider_not_installed,
        provider: :pi,
        skill: "needs-pi",
        backend: ExecutionProfile.host_backend()
      )
    end

    test "a command phase that names no skill carries a nil skill but still the backend" do
      install_harnesses(pi: false, claude: true)
      w = world("harness-plain", [command_phase(:plain, "echo hello")])
      start_executor!(w)

      run = assert_refused!(w, "provider_model_preflight_failed")

      assert_failure!(run.failure_reason, :provider_not_installed,
        skill: nil,
        backend: ExecutionProfile.host_backend()
      )
    end

    test "is reported instead of a missing skill: an absent harness's directories are not searched" do
      install_harnesses(pi: false, claude: true)
      w = world("harness-before-skill", [command_phase(:write_prd, "/skill:ghost-skill")])
      start_executor!(w)

      run = assert_refused!(w, "provider_model_preflight_failed")
      refute run.failure_reason =~ "skill_not_found"
    end
  end

  # What a refused run looks like: failed and terminal on the run and task read
  # models, the typed reason, no claim, no worktree, not one phase. Returns the
  # run projection.
  defp assert_refused!(w, reason_tuple \\ "capability_preflight_failed") do
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
        8_000
      )

    for reason <- [run.failure_reason, ProjectionStore.task_projection(w.task_id).failure_reason] do
      assert reason =~ reason_tuple
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

    run
  end

  # The refusal's `PreflightFailure` is persisted as the tuple's own `inspect`
  # text; every named field must print as `key: value` in it.
  defp assert_failure!(reason, class, fields) do
    assert reason =~ "class: #{inspect(class)}"

    for {key, value} <- fields do
      assert reason =~ "#{key}: #{inspect(value)}",
             "expected `#{key}: #{inspect(value)}` in #{reason}"
    end
  end

  defp command_phase(name, command, opts \\ []) do
    Enum.into(opts, %{name: name, command: command})
  end

  defp install_harnesses(installed) do
    Application.put_env(:foreman_server, :skill_preflight_test_installed, Map.new(installed))
  end

  # A skill pi loads: it needs a frontmatter `description`. `root` is a pi agent
  # directory's home (`<root>/.pi/agent/skills/<name>`).
  defp install_skill!(root, name) do
    write_skill!(Path.join([root, ".pi", "agent", "skills", name]), name)
  end

  # The same skill in a pi agent directory itself (`<agent_dir>/skills/<name>`).
  defp install_agent_dir_skill!(agent_dir, name) do
    write_skill!(Path.join([agent_dir, "skills", name]), name)
  end

  # A project-scoped skill: pi's project directory is `<project>/.pi/skills`.
  defp install_project_skill!(project_root, name) do
    write_skill!(Path.join([project_root, ".pi", "skills", name]), name)
  end

  defp write_skill!(dir, name) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "SKILL.md"), "---\nname: #{name}\ndescription: test skill\n---\n")
  end

  defp await_completed!(w) do
    await(fn ->
      case ProjectionStore.run(w.run_id) do
        %{status: "completed"} -> {:ok, :completed}
        %{status: "failed"} = run -> flunk("the run failed: #{inspect(run.failure_reason)}")
        _ -> :waiting
      end
    end)
  end

  # A project (a real git repository, so a worktree could be made) and an
  # admitted run whose phases are `phases`. `worktree?: false` lets the
  # proceeding runs skip the checkout; the refused ones keep the default-on
  # worktree, so "no worktree" is a real absence.
  defp world(label, phases, worktree? \\ true, opts \\ []) do
    project_id = "project-skill-#{label}-#{System.unique_integer([:positive])}"
    db = "/abs/skill-preflight/#{project_id}.db"
    repo = init_repo!(project_id)
    register_project!(project_id, db, repo)

    # The project's environment record: what the launch's environment gets
    # overlaid with (`vars` such as `PI_CODING_AGENT_DIR`).
    if vars = opts[:vars] do
      dispatch_system!("project.environment.set", "project:#{project_id}", %{
        project_id: project_id,
        vars: vars
      })

      await(fn ->
        case ForemanServer.ProjectEnvironment.environment(project_id)["vars"] do
          ^vars -> {:ok, vars}
          other -> {:waiting, other}
        end
      end)
    end

    task_id = "task-skill-#{label}-#{System.unique_integer([:positive])}"
    run_id = UniqueIds.unique_run_id("skill-#{label}")
    approval_id = "approval-#{run_id}"
    FakeTaskProvider.put_issue(db, task_id, "open")

    artifact_dir = Path.join(System.tmp_dir!(), "skill-preflight-#{run_id}")
    File.mkdir_p!(artifact_dir)
    on_exit(fn -> File.rm_rf(artifact_dir) end)

    phases =
      for phase <- phases do
        Map.merge(phase, %{
          artifact_template: %{
            path: Path.join([artifact_dir, "{run_id}-{task_id}-#{phase.name}.md"])
          },
          context: %{"script_key" => run_id}
        })
      end

    snapshot =
      %{phases: phases}
      |> then(&if(worktree?, do: &1, else: Map.put(&1, :worktree, %{enabled: false})))

    dispatch_system!("task.create", "task:#{task_id}", %{
      task_id: task_id,
      project_id: project_id,
      task_type: "implement",
      title: "skill preflight #{task_id}"
    })

    dispatch_system!("task.approve", "task:#{task_id}", %{
      task_id: task_id,
      approval_id: approval_id,
      approved_by: "skill-preflight-test",
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

    %{project_id: project_id, db: db, task_id: task_id, run_id: run_id, repo: repo}
  end

  defp init_repo!(project_id) do
    repo = Path.join(System.tmp_dir!(), "skill-preflight-repo-#{project_id}")
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

    for e <- recorded,
        do: {ForemanServer.Aggregate.event_type(e), ForemanServer.Aggregate.event_payload(e)}
  end

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
