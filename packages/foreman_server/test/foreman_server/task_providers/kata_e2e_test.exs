defmodule ForemanServer.TaskProviders.KataE2ETest do
  @moduledoc """
  A Foreman run against a REAL `kata` (TRD-KATA-T044-TEST): nothing about the `kata` process is
  scripted. The real `RunExecutor` drives a real phase in a real git worktree, the real
  `KataAdapter` answers its provider calls, and `SystemKataRunner` spawns the installed `kata`
  binary against a scratch workspace whose daemon state lives in a `KATA_HOME` of this module's own.

  Isolation. `KATA_HOME` (and a short `TMPDIR`, so the daemon's unix socket path stays under the OS
  limit) is set in this VM's process environment for the life of the module and restored afterwards;
  it is never Foreman configuration. `KATA_SERVER` and `KATA_AUTH_TOKEN` are cleared for the same
  span so no call can reach a daemon that is not this module's. The daemon the first `kata` call
  starts is stopped, by this `KATA_HOME`, and the directory removed when the module ends.

  Exclusion. The whole module is skipped (ExUnit reports it as skipped, never failed, and no setup
  runs) when `kata` is not on `PATH` at load time, or when `$HOME` is so long that the scratch
  `KATA_HOME` would exceed the length at which `kata`'s daemon socket path stops fitting the OS
  limit (probed on v0.23.0: 60 bytes work, 70 do not, so the budget is 55 to leave room for a longer
  socket file name; the local-ci gate's scratch HOME is such a case). A path that long cannot be
  made shorter without leaving `$HOME`, and scratch is never put under `/tmp`.

  What is observed. State is read back with the `kata` CLI itself (`status`, `show`, `ready`,
  `events`), not through `KataAdapter`, so the assertions do not share a parser with the code under
  test. That the adapter really spawned the binary is proven by the `subprocess.spawned` telemetry
  of `SystemKataRunner`, which only that runner emits.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{AgentRuntime, CommandGateway, ProjectionStore, RunAdmission}
  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProviders.{KataAdapter, SystemKataRunner}
  alias ForemanServer.TestSupport.{DispatcherRestart, RunSlotsReset}
  alias ForemanServer.Workflow.RunExecutor

  # The base of this module's `KATA_HOME`. `kata_home_bytes` adds the `/` and the 8 hex digits of
  # the per-run directory. The two sizes are variables, not attributes: when `kata` is off `PATH`
  # the cond below never reads the second branch, and an attribute that is set but not read is a
  # compile warning (an error under `--warnings-as-errors`).
  @kata_home_base Path.join([System.user_home!(), ".foreman", "kata-e2e"])
  kata_home_bytes = byte_size(@kata_home_base) + 9
  max_kata_home_bytes = 55

  cond do
    is_nil(System.find_executable("kata")) ->
      @moduletag skip: "kata is not on PATH: the Kata end-to-end test needs the real binary"

    kata_home_bytes > max_kata_home_bytes ->
      @moduletag skip:
                   "$HOME is too long for kata's daemon socket (#{kata_home_bytes} > #{max_kata_home_bytes} bytes of KATA_HOME)"

    true ->
      :ok
  end

  @poll_timeout_ms 20_000
  @spawned_event [:foreman_server, :task_provider, :kata, :subprocess, :spawned]
  @foreman_actor "foreman-runner"
  # The close message and the evidence Kata stored are read back from `kata events`.
  @min_close_message 40
  @env_keys ["KATA_HOME", "TMPDIR", "KATA_SERVER", "KATA_AUTH_TOKEN"]

  defmodule LifecycleStore do
    @moduledoc false
    use Agent

    def start_link(opts \\ []) do
      Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
    end

    def put(script_key, data), do: Agent.update(__MODULE__, &Map.put(&1, script_key, data))

    def take(script_key, field, default) do
      Agent.get_and_update(__MODULE__, fn state ->
        script = Map.get(state, script_key, %{})

        {result, rest} =
          case Map.get(script, field, []) do
            [value | tail] -> {value, tail}
            [] -> {default, []}
          end

        {result, Map.put(state, script_key, Map.put(script, field, rest))}
      end)
    end

    # Overwatch relaunches a crashed worker, and a clean exit does not seal the Worker aggregate, so
    # only the first launch of a phase may drive its script.
    def claim_execution(script_key) do
      Agent.get_and_update(__MODULE__, fn state ->
        script = Map.get(state, script_key, %{})

        if Map.get(script, :claimed?, false) do
          {false, state}
        else
          {true, Map.put(state, script_key, Map.put(script, :claimed?, true))}
        end
      end)
    end
  end

  # The legacy synchronous backend `Overwatch` still resolves a provider through; the phases run on
  # `TestWorkerAdapter` below.
  defmodule TestAdapter do
    @moduledoc false
    @behaviour ForemanServer.AgentRuntime.BackendAdapter

    @impl true
    def name, do: :pi

    @impl true
    def capabilities do
      %{
        type: :cli,
        strengths: [:workflow_execution],
        weaknesses: [:none],
        supported_contexts: [:implement, :test]
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "artifact body", %{}}
  end

  # The agent of a phase, on the Overwatch worker protocol: it runs the phase's `after_execute`
  # script inside the worktree it is handed (the agent's own file writes) and answers with the
  # scripted `adapter_results`. This is the only fake in the module, and it is the agent, not Kata.
  defmodule TestWorkerAdapter do
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
      context = Map.get(Keyword.fetch!(state, :phase), :context, %{})
      script_key = Map.fetch!(context, "script_key")

      if Process.whereis(LifecycleStore) != nil and
           LifecycleStore.claim_execution(script_key) do
        result = run_phase(state, script_key)

        _ =
          WorkerProtocol.emit(:worker_exited, %{
            worker_id: Keyword.fetch!(state, :worker_id),
            run_id: Keyword.fetch!(state, :run_id)
          })

        case Keyword.get(state, :result_recipient) do
          pid when is_pid(pid) -> send(pid, {:worker_result, result})
          _ -> :ok
        end
      else
        _ =
          WorkerProtocol.emit(:worker_exited, %{
            worker_id: Keyword.fetch!(state, :worker_id),
            run_id: Keyword.fetch!(state, :run_id)
          })
      end

      {:stop, :normal, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}

    defp run_phase(state, script_key) do
      env = Keyword.get(state, :env_map, %{})
      result = LifecycleStore.take(script_key, :adapter_results, {:ok, "artifact body", %{}})

      case LifecycleStore.take(script_key, :after_execute, nil) do
        fun when is_function(fun, 1) -> fun.(Map.fetch!(env, "FOREMAN_WORKTREE_PATH"))
        _ -> :ok
      end

      case result do
        {:ok, content, _metadata} -> {:ok, content}
        other -> other
      end
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)

    ensure_started(
      {Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
      ForemanServer.RunExecutorRegistry
    )

    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)
    ensure_started(AdapterCatalog, AdapterCatalog)

    ensure_started(
      ForemanServer.AgentRuntime.InvocationSupervisor,
      ForemanServer.AgentRuntime.InvocationSupervisor
    )

    ensure_started(TaskProviderRegistry, TaskProviderRegistry)

    ensure_started(
      ForemanServer.Agents.JidoShellRunner,
      ForemanServer.Agents.JidoShellRunner
    )

    # Phase execution always goes through `Overwatch.start_phase/2`; it is off by default in the
    # test config, and this module drives whole phases.
    ensure_started(ForemanServer.Overwatch, ForemanServer.Overwatch)

    previous_backend_adapter = previous_backend_adapter()
    ensure_test_adapter_registered(previous_backend_adapter)
    on_exit(fn -> restore_backend_adapter(previous_backend_adapter) end)

    # `config/test.exs` binds the Mox runner; the real one is bound for this module only, and the
    # adapter reads the binding on every call.
    previous_runner = Application.fetch_env(:foreman_server, :kata_runner)
    Application.put_env(:foreman_server, :kata_runner, SystemKataRunner)

    home = isolate_kata_env!()

    on_exit(fn ->
      stop_kata_daemon!(home)
      File.rm_rf!(home)
      # Only the module's own base directory, and only when nothing else lives in it.
      _ = File.rmdir(Path.dirname(home))
      restore_env!(home)

      case previous_runner do
        {:ok, runner} -> Application.put_env(:foreman_server, :kata_runner, runner)
        :error -> Application.delete_env(:foreman_server, :kata_runner)
      end
    end)

    {:ok, home: home}
  end

  setup %{home: home} do
    test_pid = self()
    RunSlotsReset.reset!()

    previous_worker_adapter = Application.get_env(:foreman_server, :worker_adapter)
    Application.put_env(:foreman_server, :worker_adapter, TestWorkerAdapter)

    previous_task_provider = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: @foreman_actor,
      accepted_contract_versions: ["br.capabilities.v1", "kata.capabilities.v1"],
      providers: [KataAdapter]
    )

    ForemanServer.TestSupport.TestApplication.reset_application_child!(TaskProviderRegistry)

    dispatcher = Process.whereis(ForemanServer.Workflow.Dispatcher)

    if dispatcher do
      :sys.suspend(dispatcher)
      on_exit(fn -> DispatcherRestart.restart!() end)
    end

    start_supervised!({LifecycleStore, name: LifecycleStore})

    spawned_ref = :telemetry_test.attach_event_handlers(test_pid, [@spawned_event])

    on_exit(fn ->
      :telemetry.detach(spawned_ref)

      case previous_worker_adapter do
        nil -> Application.delete_env(:foreman_server, :worker_adapter)
        adapter -> Application.put_env(:foreman_server, :worker_adapter, adapter)
      end

      Application.put_env(:foreman_server, :task_provider, previous_task_provider)
    end)

    {:ok, home: home, spawned_ref: spawned_ref}
  end

  test "the adapter drives the real kata binary: the issue it creates is in the scratch daemon, and a process was spawned for it",
       %{home: home, spawned_ref: spawned_ref} do
    # The binding every other test relies on: not the Mox runner `config/test.exs` sets.
    assert Application.get_env(:foreman_server, :kata_runner) == SystemKataRunner

    workspace = new_workspace!(home)
    project_id = unique_id("project")

    assert :ok =
             TaskProviderRegistry.register_for_project(project_id, KataAdapter, %{cwd: workspace})

    title = "e2e wiring #{System.unique_integer([:positive])}"

    assert {:ok, %Issue{id: ref, title: ^title, status: status}} =
             KataAdapter.create(project_id, %{
               title: title,
               description: "created by the Kata end-to-end test",
               task_id: unique_id("task"),
               command_id: unique_id("command")
             })

    assert status in ["open", :open]

    # `SystemKataRunner` is the only emitter of this event, one per spawned `kata` process.
    assert_received {@spawned_event, ^spawned_ref, %{}, %{os_pid: os_pid}}
    assert is_integer(os_pid) and os_pid > 0

    # Read back by the CLI, not by the adapter: the daemon holds an issue with this id and title.
    shown = kata_json!(["show", ref, "--json"], workspace, home)
    assert shown["issue"]["short_id"] == ref
    assert shown["issue"]["title"] == title
    assert shown["issue"]["status"] == "open"
  end

  describe "a run against a real Kata workspace" do
    test "success: open, then owned by the actor the daemon reports, then closed with typed evidence",
         %{home: home, spawned_ref: spawned_ref} do
      run = new_run!(home, :dirty)
      ws = run.workspace
      ref = run.ref

      # Before the run: open, unowned, and offered by `kata ready --unowned`.
      before_status = kata_status!(home, ws, ref)
      assert before_status["issue_status"] == "open"
      assert before_status["hold"] == "unassigned"
      refute Map.has_key?(before_status, "owner")
      assert ref in ready_unowned!(home, ws)
      actor = before_status["actor"]
      assert is_binary(actor) and actor != ""

      start_executor!(run)

      # The agent runs only after the claim: asked from inside the phase, Kata already shows the
      # issue owned by the daemon's actor.
      assert_receive {:status_during_agent, during}, @poll_timeout_ms
      assert during["owner"] == actor
      assert during["hold"] == "assigned"
      assert during["issue_status"] == "open"
      refute ref in ready_unowned!(home, ws)

      assert %{status: "completed"} = await_run!(run.run_id, "completed")
      assert %{status: "closed"} = await_task!(run.task_id, "closed")

      # After the run: closed, and no longer offered.
      shown = kata_json!(["show", ref, "--json"], ws, home)
      assert shown["issue"]["status"] == "closed"
      refute ref in ready_unowned!(home, ws)

      # The history, in order: created, claimed (by the actor), closed. No release, no reopen.
      events = issue_events!(home, ws, ref)
      assert Enum.map(events, & &1["type"]) == ["issue.created", "issue.assigned", "issue.closed"]

      assigned = Enum.at(events, 1)
      assert assigned["payload"]["owner"] == actor

      # The close is typed evidence Kata stored: the commit Foreman's `:commit` step made for the
      # phase, which is the tip of the run's branch.
      tip = git!(run.repo, ["rev-parse", "--verify", run.branch])
      assert git!(run.repo, ["rev-list", "--count", "#{run.base}..#{run.branch}"]) == "1"
      closed = Enum.at(events, 2)
      assert closed["payload"]["reason"] == "done"
      assert closed["payload"]["evidence"] == [%{"type" => "commit", "sha" => tip}]

      assert String.starts_with?(
               closed["payload"]["message"],
               "foreman-run:#{run.run_id}:#{artifact_path(run)}"
             )

      assert String.length(closed["payload"]["message"]) >= @min_close_message

      # Every call above reached the real binary (claim and close at least; the create ran before
      # the executor).
      assert spawned_count(spawned_ref) >= 2
    end

    test "failure: reopened, commented and released: open, unowned, listed by `kata ready --unowned`, claimable again",
         %{home: home, spawned_ref: spawned_ref} do
      run = new_run!(home, :fail)
      ws = run.workspace
      ref = run.ref

      before_status = kata_status!(home, ws, ref)
      actor = before_status["actor"]
      assert is_binary(actor) and actor != ""

      start_executor!(run)

      assert_receive {:status_during_agent, during}, @poll_timeout_ms
      assert during["owner"] == actor
      assert during["hold"] == "assigned"

      assert %{failure_reason: reason} = await_task!(run.task_id, "failed")
      assert %{status: "failed"} = await_run!(run.run_id, "failed")
      assert is_binary(reason) and reason != ""

      # Open, and nobody owns it: no `owner` key at all, and Kata calls the hold unassigned.
      after_status = kata_status!(home, ws, ref)
      assert after_status["issue_status"] == "open"
      assert after_status["hold"] == "unassigned"
      refute Map.has_key?(after_status, "owner")
      assert after_status["actor"] == actor

      shown = kata_json!(["show", ref, "--json"], ws, home)
      assert shown["issue"]["status"] == "open"

      # It was never closed. It was claimed, commented on with the failure, and released.
      events = issue_events!(home, ws, ref)

      assert Enum.map(events, & &1["type"]) == [
               "issue.created",
               "issue.assigned",
               "issue.commented",
               "issue.unassigned"
             ]

      [_created, assigned, commented, unassigned] = events
      assert assigned["payload"]["owner"] == actor
      assert commented["payload"]["body"] == reason
      assert commented["payload"]["idempotency_key"] == failure_key(run.run_id, reason)
      assert unassigned["payload"]["owner"] == nil

      # The comment is on the issue as Kata shows it.
      assert [%{"body" => ^reason}] = shown["comments"]

      # Listed by `kata ready --unowned` ...
      assert ref in ready_unowned!(home, ws)

      # ... and claimable again, by another run, as the actor the daemon reports.
      assert {:ok, %Issue{id: ^ref, assignee: ^actor}} =
               RunExecutor.claim(run.project_id, ref, @foreman_actor, unique_id("run"))

      reclaimed = kata_status!(home, ws, ref)
      assert reclaimed["owner"] == actor
      assert reclaimed["hold"] == "assigned"
      refute ref in ready_unowned!(home, ws)

      # Claim, status, reopen, comment, unassign, and the second claim: all real processes.
      assert spawned_count(spawned_ref) >= 6
    end
  end

  # ---------------------------------------------------------------------------
  # Kata isolation
  # ---------------------------------------------------------------------------

  # A short directory (a unix socket path is limited to ~100 bytes on macOS) that is this module's
  # `KATA_HOME` and `TMPDIR` for the module's life. The previous values are kept by `restore_env!/1`.
  defp isolate_kata_env!() do
    base = @kata_home_base
    home = Path.join(base, Base.encode16(:crypto.strong_rand_bytes(4), case: :lower))
    File.mkdir_p!(home)

    previous = Map.new(@env_keys, &{&1, System.get_env(&1)})
    :persistent_term.put({__MODULE__, home}, previous)

    System.put_env("KATA_HOME", home)
    System.put_env("TMPDIR", home)
    # A call must never reach a daemon that is not this module's.
    System.delete_env("KATA_SERVER")
    System.delete_env("KATA_AUTH_TOKEN")
    home
  end

  defp restore_env!(home) do
    previous = :persistent_term.get({__MODULE__, home})
    :persistent_term.erase({__MODULE__, home})

    Enum.each(previous, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  # Stops the daemon of THIS `KATA_HOME` and proves it is gone. Nothing else is signalled.
  defp stop_kata_daemon!(home) do
    {_output, _status} = kata(["daemon", "stop"], home, home)
    {status, _} = kata(["daemon", "status"], home, home)

    unless status =~ "No kata daemon is running" do
      raise "the kata daemon of #{home} is still running after `kata daemon stop`: #{status}"
    end
  end

  # A git repository bound to a fresh Kata project of the scratch daemon.
  defp new_workspace!(home) do
    repo = Path.join(home, "ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(repo)
    git!(repo, ["init", "--initial-branch=main", "--quiet"])
    git!(repo, ["config", "user.email", "t@x"])
    git!(repo, ["config", "user.name", "T"])
    File.write!(Path.join(repo, "README.md"), "x")

    {out, status} = kata(["init", "--project", "e2e-#{Path.basename(repo)}"], repo, home)
    assert status == 0, "kata init failed: #{out}"

    # The binding file `kata init` wrote is part of the repository, as in a real project.
    git!(repo, ["add", "."])
    git!(repo, ["commit", "--no-gpg-sign", "--quiet", "-m", "init"])
    repo
  end

  defp kata(args, cwd, home) do
    System.cmd("kata", args,
      cd: cwd,
      env: [{"KATA_HOME", home}, {"TMPDIR", home}],
      stderr_to_stdout: true
    )
  end

  defp kata_json!(args, cwd, home) do
    {out, status} = kata(args, cwd, home)
    assert status == 0, "kata #{Enum.join(args, " ")} exited #{status}: #{out}"
    Jason.decode!(out)
  end

  defp kata_status!(home, workspace, ref),
    do: kata_json!(["status", ref, "--json"], workspace, home)

  defp ready_unowned!(home, workspace) do
    ["ready", "--unowned", "--json"]
    |> kata_json!(workspace, home)
    |> Map.fetch!("issues")
    |> Enum.map(& &1["short_id"])
  end

  # What Kata recorded for the issue, oldest first.
  defp issue_events!(home, workspace, ref) do
    ["events", "--after", "0", "--limit", "1000", "--json"]
    |> kata_json!(workspace, home)
    |> Map.fetch!("events")
    |> Enum.filter(&(&1["issue_short_id"] == ref))
  end

  defp spawned_count(spawned_ref, count \\ 0) do
    receive do
      {@spawned_event, ^spawned_ref, %{}, %{os_pid: _os_pid}} ->
        spawned_count(spawned_ref, count + 1)
    after
      0 -> count
    end
  end

  # ---------------------------------------------------------------------------
  # Runs
  # ---------------------------------------------------------------------------

  # A project bound to a real Kata workspace, an issue created by the real `KataAdapter.create/2`, a
  # task linked to it, and a run admitted for it. `kind` is what the phase's agent does in its
  # worktree: `:dirty` (writes a file and leaves it for Foreman to commit) or `:fail`. Either way
  # the agent first reports, to the test, what Kata shows for the issue while the agent runs.
  defp new_run!(home, kind) do
    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    repo = new_workspace!(home)
    artifact_dir = Path.join(home, unique_id("artifacts"))
    File.mkdir_p!(artifact_dir)

    on_exit(fn ->
      File.rm_rf(repo)
      File.rm_rf(artifact_dir)
      File.rm_rf(Path.join([System.user_home!(), ".foreman/worktrees", project_id]))
    end)

    assert :ok = TaskProviderRegistry.register_for_project(project_id, KataAdapter, %{cwd: repo})

    assert {:ok, %Issue{id: ref}} =
             KataAdapter.create(project_id, %{
               title: "Kata e2e #{task_id}",
               description: "a task for the Kata end-to-end test",
               task_id: task_id,
               command_id: unique_id("command")
             })

    script_key = unique_id("script")
    observe = fn -> send(test_pid, {:status_during_agent, kata_status!(home, repo, ref)}) end
    LifecycleStore.put(script_key, agent_script(kind, observe))

    workflow_snapshot = %{
      phases: [
        %{
          name: "implement-1",
          artifact_template: %{path: Path.join(artifact_dir, "{run_id}-implement-1.md")},
          context: %{"script_key" => script_key}
        }
      ]
    }

    seed_task_and_run!(project_id, task_id, run_id, workflow_snapshot, ref, repo)

    %{
      project_id: project_id,
      task_id: task_id,
      run_id: run_id,
      ref: ref,
      repo: repo,
      workspace: repo,
      branch: "foreman/#{ref}/#{run_id}",
      base: git!(repo, ["rev-parse", "HEAD"]),
      artifact_dir: artifact_dir
    }
  end

  defp agent_script(:dirty, observe) do
    %{
      after_execute: [
        fn worktree ->
          observe.()
          File.write!(Path.join(worktree, "phase-1.txt"), "work of phase 1")
          :ok
        end
      ]
    }
  end

  defp agent_script(:fail, observe) do
    %{
      adapter_results: [{:error, :boom}],
      after_execute: [
        fn _worktree ->
          observe.()
          :ok
        end
      ]
    }
  end

  defp artifact_path(run), do: Path.join(run.artifact_dir, "#{run.run_id}-implement-1.md")

  defp start_executor!(run) do
    task = ProjectionStore.task_projection(run.task_id)

    start_supervised!(%{
      id: {RunExecutor, run.run_id},
      start: {RunExecutor, :start_link, [run.run_id, task]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    })
  end

  defp seed_task_and_run!(project_id, task_id, run_id, workflow_snapshot, ref, repo) do
    seed_project!(project_id, repo)
    approval_id = unique_id("approval")

    dispatch_system!("task.create", "task:#{task_id}", %{
      task_id: task_id,
      project_id: project_id,
      task_type: "implement",
      title: "Kata e2e #{task_id}",
      external_id: ref
    })

    dispatch_system!("task.approve", "task:#{task_id}", %{
      task_id: task_id,
      approval_id: approval_id,
      approved_by: "kata-e2e-test",
      approved_at: "2026-11-19T00:00:00Z",
      run_id: run_id,
      workflow_snapshot: workflow_snapshot
    })

    dispatch_system!("task.dispatch", "task:#{task_id}", %{task_id: task_id})

    assert {:ok, result} =
             RunAdmission.start(project_id, %{
               run_id: run_id,
               task_id: task_id,
               project_id: project_id,
               approval_id: approval_id,
               workflow_snapshot: workflow_snapshot,
               phase_specs: Map.get(workflow_snapshot, :phases, [])
             })

    refute result in [:slot_queued, :queued, nil],
           "RunAdmission.start returned #{inspect(result)}: the seeded run did not start"
  end

  # The config reaches the projection as JSON ingress sends it: the string key `"cwd"`.
  defp seed_project!(project_id, path) do
    dispatch_system!("project.register", "project:#{project_id}", %{
      project_id: project_id,
      name: "Kata e2e #{project_id}",
      path: path,
      task_provider: %{provider: "kata", config: %{"cwd" => path}}
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

  defp failure_key(run_id, body) do
    hash = :sha256 |> :crypto.hash(body) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    "foreman-fail:#{run_id}:#{hash}"
  end

  # ---------------------------------------------------------------------------
  # Waiting
  # ---------------------------------------------------------------------------

  defp await_run!(run_id, status) do
    poll_until(
      fn ->
        case ProjectionStore.run(run_id) do
          %{status: ^status} = run -> {:ok, run}
          other -> {:error, other}
        end
      end,
      "run #{status}"
    )
  end

  defp await_task!(task_id, status) do
    poll_until(
      fn ->
        case ProjectionStore.task_projection(task_id) do
          %{status: ^status} = task -> {:ok, task}
          other -> {:error, other}
        end
      end,
      "task #{status}"
    )
  end

  defp poll_until(fun, label) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll(fun, deadline, label)
  end

  defp do_poll(fun, deadline, label) do
    case fun.() do
      {:ok, value} ->
        value

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timed out waiting for #{label} (last: #{inspect(other)})")
        else
          Process.sleep(25)
          do_poll(fun, deadline, label)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Git and ids
  # ---------------------------------------------------------------------------

  defp git!(repo, args) do
    {output, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    String.trim(output)
  end

  defp unique_id(prefix) do
    "#{prefix}-kata-e2e-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  # ---------------------------------------------------------------------------
  # Process and adapter fixtures
  # ---------------------------------------------------------------------------

  defp ensure_started(child_spec, name) do
    if Process.whereis(name) do
      :ok
    else
      start_supervised!(child_spec)
      :ok
    end
  end

  defp ensure_test_adapter_registered(previous_backend_adapter) do
    case previous_backend_adapter do
      TestAdapter ->
        :ok

      module when is_atom(module) and not is_nil(module) ->
        unregister_adapter(module)
        {:ok, _} = AgentRuntime.register_adapter(TestAdapter)
        :ok

      nil ->
        {:ok, _} = AgentRuntime.register_adapter(TestAdapter)
        :ok
    end
  end

  defp restore_backend_adapter(previous_backend_adapter) do
    case previous_backend_adapter do
      TestAdapter ->
        :ok

      module when is_atom(module) and not is_nil(module) ->
        unregister_adapter(TestAdapter)
        {:ok, _} = AgentRuntime.register_adapter(module)
        :ok

      nil ->
        unregister_adapter(TestAdapter)
        :ok
    end
  end

  defp unregister_adapter(module) do
    if Process.whereis(AdapterCatalog) do
      case AdapterCatalog.unregister(module) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    else
      :ok
    end
  end

  defp previous_backend_adapter do
    configured =
      Application.get_env(:foreman_server, :agent_runtime, [])
      |> Keyword.get(:adapters, [])
      |> Enum.find_value(fn
        adapter when is_atom(adapter) ->
          case AdapterCatalog.lookup(adapter.name()) do
            {:ok, module} -> module
            {:error, :not_found} -> nil
          end

        _ ->
          nil
      end)

    configured ||
      case AdapterCatalog.routing_snapshot() do
        [%{adapter: module} | _] -> module
        _ -> nil
      end
  end
end
