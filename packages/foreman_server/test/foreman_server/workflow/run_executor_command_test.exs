defmodule ForemanServer.Workflow.RunExecutorCommandTest do
  @moduledoc """
  Integration tests for the `command:` phase action and the
  `requiredFile` gate. These tests drive the real `RunExecutor`
  GenServer end-to-end and assert against the bytes captured by the
  test adapter, not against reimplemented helper logic.
  """

  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.{AgentRuntime, CommandGateway, Identity, ProjectionStore, RunAdmission}
  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProviders.{BeadsAdapter, BrRunnerMock, JsonSchemaCache}
  alias ForemanServer.Workflow.RunExecutor
  alias ForemanServer.TestSupport.RunSlotsReset
  @cache_name :foreman_server_json_schema_cache
  @poll_timeout_ms 8_000

  defmodule LifecycleStore do
    use Agent
    def start_link(opts \\ []) do
      Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
    end

    def clear do
      Agent.update(__MODULE__, fn _ -> %{} end)
    end

    def put(script_key, data) do
      Agent.update(__MODULE__, &Map.put(&1, script_key, data))
    end

    def test_pid(script_key) do
      Agent.get(__MODULE__, &get_in(&1, [script_key, :test_pid]))
    end

    # Overwatch/LaunchWorker restarts a worker's supervised process
    # `:permanent`ly on ANY exit (see worker_supervisor.ex), and a clean
    # WorkerExited does not seal the Worker aggregate — only
    # WorkerCrashed/RunCompleted/RunFailed do (see aggregates/worker.ex).
    # A finished phase can therefore be re-launched by the supervisor
    # before the run has fully completed. TestWorkerAdapter uses this to
    # detect a duplicate re-launch and avoid re-driving the script.
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

  defmodule TestAdapter do
    @behaviour ForemanServer.AgentRuntime.BackendAdapter

    @impl true
    def name, do: :pi

    @impl true
    def capabilities do
      %{
        type: :cli,
        strengths: [:workflow_execution],
        weaknesses: [:none],
        supported_contexts: [:implement, :test, :plan]
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(%{prompt: prompt, context: context}, _opts) do
      # Tests that gate on a relative `required_file` need the file to
      # exist inside the worktree BEFORE the executor runs the post-agent
      # gate. The `write_paths` entry is a list of bare filenames (joined
      # against `working_directory`) the adapter materializes on disk.
      # Materialize BEFORE forwarding `:adapter_execute` so the test
      # process can assert the file's existence on receive without racing
      # the adapter's remaining work.
      working_directory = Map.get(context, "working_directory")
      write_paths = Map.get(context, "write_paths") || []

      if is_binary(working_directory) and working_directory != "" do
        Enum.each(write_paths, fn relative ->
          target = Path.join(working_directory, relative)
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, "gate file materialized by TestAdapter")
        end)
      end

      script_key = Map.fetch!(context, "script_key")

      if pid = LifecycleStore.test_pid(script_key) do
        send(pid, {:adapter_execute, prompt, context})
      end

      {:ok, "artifact body", %{}}
    end
  end

  # Phase execution (LGC-T002/JHA-T002) always routes through
  # Overwatch.start_phase/2, which spawns whatever module
  # `Application.get_env(:foreman_server, :worker_adapter, ...)` names as
  # a supervised worker following the Overwatch worker protocol (see
  # ForemanServer.Overwatch.Adapters.JidoHarnessWorker for the production
  # contract this mirrors): `start_link/1`, reply to the
  # `{:overwatch_activate, worker_id, run_id, parent}` handshake with
  # `{:overwatch_activated, self()}`, run the phase, then report
  # completion with `{:worker_result, result}` sent directly to
  # `opts[:result_recipient]` and stop — exactly what
  # JidoHarnessWorker.handle_info({:agent_done, result}, state) does
  # after a real agent run completes. `TestAdapter` above implements the
  # legacy synchronous `BackendAdapter.execute/2` callback, which this
  # pipeline never calls.
  defmodule TestWorkerAdapter do
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
      phase = Keyword.fetch!(state, :phase)
      context = Map.get(phase, :context, %{})
      script_key = Map.fetch!(context, "script_key")

      # See LifecycleStore.claim_execution/1: Overwatch/LaunchWorker
      # restarts this worker :permanently on ANY exit, and a clean
      # WorkerExited does not seal the Worker aggregate, so the
      # supervisor can re-launch it for a phase that already delivered
      # its result. Only the first (winning) launch drives the script
      # and reports a result; a duplicate re-launch finishes the
      # handshake quietly — re-sending {:worker_result, ...} would hit a
      # RunExecutor that already moved past this phase and has no
      # catch-all handle_info/2 clause to absorb the stray message.
      # A duplicate re-launch can fire well after its originating test
      # has already finished (LifecycleStore is start_supervised! per
      # test, but Overwatch's crash-loop backoff can delay the retry
      # past that window) — guard against calling a dead Agent.
      claimed? =
        Process.whereis(LifecycleStore) != nil and LifecycleStore.claim_execution(script_key)

      if claimed? do
        result = run_phase(state, context)

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

    defp run_phase(state, context) do
      prompt = Keyword.fetch!(state, :prompt)

      # Mirrors TestAdapter.execute/2 above: materialize any relative
      # write_paths inside the worktree BEFORE forwarding :adapter_execute,
      # so the requiredFile gate sees the file on disk.
      working_directory = Map.get(context, "working_directory")
      write_paths = Map.get(context, "write_paths") || []

      if is_binary(working_directory) and working_directory != "" do
        Enum.each(write_paths, fn relative ->
          target = Path.join(working_directory, relative)
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, "gate file materialized by TestWorkerAdapter")
        end)
      end

      env = Keyword.get(state, :env_map) || %{}

      script_key = Map.fetch!(context, "script_key")

      if pid = LifecycleStore.test_pid(script_key) do
        send(pid, {:adapter_execute, prompt, context})
        send(pid, {:adapter_env, env})
      end

      {:ok, "artifact body"}
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

    ensure_started(
      ForemanServer.AgentRuntime.AdapterCatalog,
      ForemanServer.AgentRuntime.AdapterCatalog
    )

    ensure_started(
      ForemanServer.AgentRuntime.InvocationSupervisor,
      ForemanServer.AgentRuntime.InvocationSupervisor
    )

    # Phase execution always routes through Overwatch.start_phase/2
    # (LGC-T002/JHA-T002 — see run_executor.ex execute_agent/4). Overwatch
    # is disabled by default in test config (config/test.exs); this file
    # drives full RunExecutor phases end to end, so it needs the
    # supervisor tree up, mirroring overwatch_test.exs's own opt-in.
    ensure_started(ForemanServer.Overwatch, ForemanServer.Overwatch)

    previous_backend_adapter = previous_backend_adapter()

    ensure_test_adapter_registered(previous_backend_adapter)

    on_exit(fn ->
      restore_backend_adapter(previous_backend_adapter)
    end)

    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    RunSlotsReset.reset!()

    previous_worker_adapter = Application.get_env(:foreman_server, :worker_adapter)
    Application.put_env(:foreman_server, :worker_adapter, TestWorkerAdapter)

    on_exit(fn ->
      case previous_worker_adapter do
        nil -> Application.delete_env(:foreman_server, :worker_adapter)
        adapter -> Application.put_env(:foreman_server, :worker_adapter, adapter)
      end
    end)
    previous_task_provider = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: "foreman-runner",
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    stop_schema_cache()
    ForemanServer.TestSupport.TestApplication.reset_application_child!(TaskProviderRegistry)
    dispatcher = Process.whereis(ForemanServer.Workflow.Dispatcher)

    if dispatcher do
      :sys.suspend(dispatcher)

      on_exit(fn ->
        kill_and_restart_dispatcher(dispatcher)
      end)
    end

    start_supervised!({LifecycleStore, name: LifecycleStore})
    LifecycleStore.clear()

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_task_provider)
      stop_schema_cache()
    end)

    :ok
  end

  test "plan gate captures the document the agent invented and threads it to the next phase" do
    # Regression for run-d6cdefe69706087e6bce5b1a10b95384 and its two
    # predecessors. Foreman computed
    # `PRD-2026-d6cdefe6-implement-durable-run-log-store-for-foreman-run.md`
    # and the agent wrote
    # `PRD-2026-c57dc188-curated-ensemble-workflow-dispatch.md`. Foreman no
    # longer names the file: the gate asks git which new document appeared
    # under `docs/PRD`, captures that, and hands it to `create-trd`. The
    # adapter here writes ONLY the invented name, so the phase can complete
    # only if nothing checks a Foreman-computed one.
    expect_schema_boot_fetches()
    start_supervised!(JsonSchemaCache)

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")

    run_id =
      "run-" <> Base.encode16(:crypto.hash(:sha256, "task-#{task_id}-approve"), case: :lower)

    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    repo_dir = init_plan_repo!(project_id)

    invented_prd = "docs/PRD/PRD-2026-c57dc188-curated-ensemble-workflow-dispatch.md"
    invented_trd = "docs/TRD/TRD-2026-c57dc188-curated-ensemble-workflow-dispatch.md"

    workflow_snapshot = %{
      run_id: run_id,
      workflow_name: "plan",
      workflow_digest: "test-digest",
      phases: [
        %{
          name: :create_prd,
          action: :command,
          command: "/skill:ensemble-full-create-prd --foreman",
          required_file: "planning.prd_path",
          index: 1,
          phase_id: Identity.phase_id(run_id, 1),
          artifact_template: %{
            path: Path.join([artifact_dir, "{run_id}-{task_id}-create_prd.md"])
          },
          # No `worktree:` block — mirrors plan.yaml, so the executor
          # provisions the default-on worktree and the agent's cwd is that
          # worktree, never the registered checkout.
          context: %{"script_key" => "#{script_key}-1", "write_paths" => [invented_prd]}
        },
        %{
          name: :create_trd,
          action: :command,
          command: "/skill:ensemble-full-create-trd-foreman --foreman",
          required_file: "planning.trd_path",
          index: 2,
          phase_id: Identity.phase_id(run_id, 2),
          artifact_template: %{
            path: Path.join([artifact_dir, "{run_id}-{task_id}-create_trd.md"])
          },
          context: %{"script_key" => "#{script_key}-2", "write_paths" => [invented_trd]}
        }
      ]
    }

    LifecycleStore.put("#{script_key}-1", %{test_pid: test_pid})
    LifecycleStore.put("#{script_key}-2", %{test_pid: test_pid})

    seed_plan_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      database_path,
      repo_dir
    )

    expect(BrRunnerMock, :cmd, 1, fn {:update, %{flags: ["--claim", task_id]}}, _cfg, opts ->
      send(test_pid, {:runner_cmd, :claim})
      assert opts == [timeout_ms: 30_000]
      claim_payload_json(task_id)
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:close, %{id: ^task_id}}, _cfg, opts ->
      send(test_pid, {:runner_cmd, :close})
      assert opts == [timeout_ms: 30_000]
      close_payload_json(task_id)
    end)

    task = ProjectionStore.task_projection(task_id)

    run_pid =
      start_supervised!(%{
        id: {RunExecutor, run_id},
        start: {RunExecutor, :start_link, [run_id, task]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      })

    assert is_pid(run_pid)

    # ---- phase 1: create-prd -------------------------------------------
    assert_receive {:adapter_execute, _prompt, prd_context}, @poll_timeout_ms
    assert_receive {:adapter_env, prd_env}, @poll_timeout_ms

    prd_worktree = prd_env["FOREMAN_WORKTREE_PATH"]
    assert is_binary(prd_worktree) and prd_worktree != ""
    assert prd_context["working_directory"] == prd_worktree

    # Nothing names a document that does not exist yet.
    refute Map.has_key?(prd_context["planning"], "prd_path")
    refute Map.has_key?(prd_context["planning"], "trd_path")

    # The mandate is gone. Not renamed, not relocated — gone.
    refute Map.has_key?(prd_env, "FOREMAN_PRD_PATH")
    refute Map.has_key?(prd_env, "FOREMAN_TRD_PATH")

    # The subject IS delivered: discovery may only accept whatever the agent
    # produced if Foreman provably told the agent what to produce.
    assert prd_env["FOREMAN_TASK_TITLE"] == "Plan #{task_id}"
    assert prd_env["FOREMAN_TASK_DESCRIPTION"] == "Plan task description for #{task_id}"

    # Nothing has been captured yet, so there is no source PRD to consume.
    refute Map.has_key?(prd_env, "FOREMAN_SOURCE_PRD_PATH")

    assert File.regular?(Path.join(prd_worktree, invented_prd))

    # ---- phase 2: create-trd -------------------------------------------
    assert_receive {:adapter_execute, _trd_prompt, trd_context}, @poll_timeout_ms
    assert_receive {:adapter_env, trd_env}, @poll_timeout_ms

    # The captured path — the invented one — is what the next phase reads as
    # `planning.prd_path`.
    assert trd_context["planning"]["prd_path"] == invented_prd

    trd_worktree = trd_env["FOREMAN_WORKTREE_PATH"]
    assert trd_env["FOREMAN_SOURCE_PRD_PATH"] == Path.join(trd_worktree, invented_prd)
    refute Map.has_key?(trd_env, "FOREMAN_PRD_PATH")

    # Pairing follows the document that exists, not the run. The run-derived
    # id never reaches the TRD phase.
    assert trd_context["planning"]["correlation_id"] == "c57dc188"
    refute trd_context["planning"]["correlation_id"] == binary_part(run_id, 4, 8)

    for index <- [1, 2] do
      phase_id = Identity.phase_id(run_id, index)

      {:ok, phase} =
        poll_until(
          fn ->
            case ProjectionStore.phase_projection(phase_id) do
              %{status: "completed"} = phase -> {:ok, phase}
              other -> {:error, other}
            end
          end,
          "phase #{index} completed"
        )

      assert phase.status == "completed"
    end

    assert_receive {:runner_cmd, :close}, @poll_timeout_ms
  end

  test "plan gate fails loudly when the agent produced no document" do
    # Zero candidates is its own cause with its own error (AGENTS.md 5.3):
    # "the agent wrote nothing" must never read like "the agent wrote
    # something Foreman could not name".
    %{run_id: run_id, phase_id: phase_id} = run_plan_capture_phase!(write_paths: [])

    failure_reason = await_phase_failure!(phase_id)

    assert failure_reason =~ "planning_document_absent"
    assert failure_reason =~ "docs/PRD"
    refute failure_reason =~ "planning_document_ambiguous"

    await_run_failure!(run_id)
  end

  test "plan gate fails loudly and names the candidates when the agent produced several" do
    # More than one new document means Foreman cannot know which one is the
    # deliverable. Picking one (newest mtime, first alphabetically) would be
    # a coin flip reported as success, so the gate refuses and names them.
    first = "docs/PRD/PRD-2026-aaaaaaaa-first-draft.md"
    second = "docs/PRD/PRD-2026-bbbbbbbb-second-draft.md"

    %{run_id: run_id, phase_id: phase_id} = run_plan_capture_phase!(write_paths: [first, second])

    failure_reason = await_phase_failure!(phase_id)

    assert failure_reason =~ "planning_document_ambiguous"
    assert failure_reason =~ first
    assert failure_reason =~ second

    await_run_failure!(run_id)
  end

  test "a discovery-gated phase never dispatches an agent that was not told the subject" do
    # The failure discovery would otherwise hide: three live runs produced a
    # PRD on the same unrelated topic from three different task
    # descriptions. Capturing whatever the agent wrote turns that into a
    # GREEN run holding an irrelevant document. A phase whose output is
    # discovered rather than named must therefore carry the subject, or it
    # does not launch at all.
    expect_schema_boot_fetches()
    start_supervised!(JsonSchemaCache)

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")

    run_id =
      "run-" <> Base.encode16(:crypto.hash(:sha256, "task-#{task_id}-approve"), case: :lower)

    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))

    # A non-plan workflow carries no planning context, so no task subject
    # reaches the env — yet this manifest gates on a discovered document.
    workflow_snapshot = %{
      run_id: run_id,
      workflow_name: "feature",
      workflow_digest: "test-digest",
      phases: [
        %{
          name: :create_prd,
          action: :command,
          command: "/skill:ensemble-full-create-prd --foreman",
          required_file: "planning.prd_path",
          index: 1,
          phase_id: Identity.phase_id(run_id, 1),
          artifact_template: %{
            path: Path.join([artifact_dir, "{run_id}-{task_id}-create_prd.md"])
          },
          context: %{"script_key" => script_key},
          worktree: %{enabled: false}
        }
      ]
    }

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    seed_feature_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      database_path
    )

    expect(BrRunnerMock, :cmd, 1, fn {:update, %{flags: ["--claim", task_id]}}, _cfg, _opts ->
      send(test_pid, {:runner_cmd, :claim})
      claim_payload_json(task_id)
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, _cfg, _opts ->
      send(test_pid, {:runner_cmd, :reopen, request})
      claim_payload_json(task_id)
    end)

    task = ProjectionStore.task_projection(task_id)

    run_pid =
      start_supervised!(%{
        id: {RunExecutor, run_id},
        start: {RunExecutor, :start_link, [run_id, task]},
        restart: :transient,
        shutdown: 5_000,
        type: :worker
      })

    assert is_pid(run_pid)

    failure_reason = await_phase_failure!(Identity.phase_id(run_id, 1))

    assert failure_reason =~ "plan_subject_missing"
    assert failure_reason =~ "planning.prd_path"

    # The worker was never launched: no agent ran, so there was nothing to
    # discover in the first place.
    refute_received {:adapter_execute, _, _}

    await_run_failure!(run_id)
  end

  test "command: phase forwarded for feature task when requiredFile resolves through flat implementation context" do
    expect_schema_boot_fetches()
    start_supervised!(JsonSchemaCache)

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")

    run_id =
      "run-" <> Base.encode16(:crypto.hash(:sha256, "task-#{task_id}-approve"), case: :lower)

    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    trd_path = Path.join(System.tmp_dir!(), unique_id("trd") <> ".md")
    File.write!(trd_path, "# stub TRD for gate test")

    on_exit(fn -> File.rm_rf(trd_path) end)

    workflow_snapshot = %{
      run_id: run_id,
      workflow_name: "implement-trd-beads",
      workflow_digest: "test-digest",
      implementation: %{
        project_root: System.tmp_dir!(),
        source_revision: "test-#{task_id}",
        implementation_key: "test-key-#{task_id}",
        trd_path: trd_path,
        beads_database_path: database_path
      },
      phases: [
        %{
          name: :implement_trd_beads,
          action: :command,
          command: "/skill:ensemble-full-implement-trd-beads --foreman \"#{trd_path}\"",
          required_file: "trd_path",
          index: 1,
          phase_id: Identity.phase_id(run_id, 1),
          artifact_template: %{
            path: Path.join([artifact_dir, "{run_id}-{task_id}-implement.md"])
          },
          context: %{"script_key" => script_key},
          # Non-worktree test: project path is a plain System.tmp_dir!()
          # directory, not a git repo. Opt out of the TRD-2026 default-on
          # worktree (see run_executor.ex maybe_create_worktree/3).
          worktree: %{enabled: false}
        }
      ]
    }

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    seed_feature_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      database_path
    )

    expect(BrRunnerMock, :cmd, 1, fn {:update, %{flags: ["--claim", task_id]}},
                                     runner_project_config,
                                     [timeout_ms: 30_000] ->
      send(test_pid, {:runner_cmd, :claim})

      assert (Map.get(runner_project_config, :database_path) ||
                Map.get(runner_project_config, "database_path")) == database_path

      {:ok,
       %{
         stdout:
           Jason.encode!([
             %{
               "id" => task_id,
               "title" => "Feature #{task_id}",
               "status" => "in_progress",
               "priority" => 2,
               "dependencies" => [],
               "assignee" => "foreman-runner",
               "description" => "Feature task description",
               "notes" => nil,
               "design" => nil,
               "labels" => ["workflow", "in_progress"],
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             }
           ]),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:close, %{id: ^task_id}},
                                     runner_project_config,
                                     [timeout_ms: 30_000] ->
      send(test_pid, {:runner_cmd, :close})

      assert (Map.get(runner_project_config, :database_path) ||
                Map.get(runner_project_config, "database_path")) == database_path

      {:ok,
       %{
         stdout:
           Jason.encode!([
             %{
               "id" => task_id,
               "title" => "Feature #{task_id}",
               "status" => "closed",
               "priority" => 1,
               "dependencies" => [],
               "assignee" => nil,
               "description" => nil,
               "notes" => nil,
               "design" => nil,
               "labels" => [],
               "metadata" => %{}
             }
           ]),
         stderr: "",
         exit_code: 0
       }}
    end)

    task = ProjectionStore.task_projection(task_id)

    run_pid =
      start_supervised!(%{
        id: {RunExecutor, run_id},
        start: {RunExecutor, :start_link, [run_id, task]},
        restart: :transient,
        shutdown: 5_000,
        type: :worker
      })

    assert is_pid(run_pid)

    assert_receive {:adapter_execute, prompt, context}, @poll_timeout_ms
    assert is_binary(prompt)
    assert String.starts_with?(prompt, "/skill:ensemble-full-implement-trd-beads")

    assert context["trd_path"] == trd_path

    # Non-plan run: no planning context, so no plan variable is exported at
    # all — absent rather than blank (AGENTS.md 5.3).
    assert_receive {:adapter_env, env}, @poll_timeout_ms
    refute Map.has_key?(env, "FOREMAN_TASK_TITLE")
    refute Map.has_key?(env, "FOREMAN_TASK_DESCRIPTION")
    refute Map.has_key?(env, "FOREMAN_SOURCE_PRD_PATH")

    phase_id = Identity.phase_id(run_id, 1)

    {:ok, completed_phase} =
      poll_until(
        fn ->
          case ProjectionStore.phase_projection(phase_id) do
            %{status: "completed"} = phase -> {:ok, phase}
            other -> {:error, other}
          end
        end,
        "phase completed"
      )

    assert completed_phase.status == "completed"
  end

  test "requiredFile gate resolves the relative file from the active worktree, not the daemon cwd" do
    # The dispatch-daemon trap this guards: a relative `requiredFile: trd_path`
    # resolves `File.regular?("docs/TRD/...")` against the daemon cwd
    # (`packages/foreman_server`), where it never exists, so the gate fails
    # even though the file is material inside the worktree the agent just
    # provisioned. The executor MUST thread the active `worktree_record`
    # through to `enforce_required_file` so the path resolution joins
    # against the worktree root. This test creates a real git repo + real
    # worktree, writes the required file only inside the worktree, and
    # asserts the gate passes.
    expect_schema_boot_fetches()
    start_supervised!(JsonSchemaCache)

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")

    run_id =
      "run-" <> Base.encode16(:crypto.hash(:sha256, "task-#{task_id}-approve"), case: :lower)

    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))

    # Sanity-check the trap control: the relative path must NOT exist
    # in the daemon cwd before the worktree exists, otherwise the test
    # would pass even without the fix.
    assert File.regular?("TRD-GATE.md") == false

    # Real git repo with one commit — `git worktree add` requires a
    # non-empty history at HEAD to create a fresh branch.
    repo_dir = Path.join(System.tmp_dir!(), "foreman-gate-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo_dir)
    File.mkdir_p!(repo_dir)
    run_git!(["-C", repo_dir, "init", "--initial-branch=main"])
    run_git!(["-C", repo_dir, "config", "user.email", "gate@test"])
    run_git!(["-C", repo_dir, "config", "user.name", "Gate Test"])
    File.write!(Path.join(repo_dir, "README.md"), "seed")
    run_git!(["-C", repo_dir, "add", "."])
    run_git!(["-C", repo_dir, "commit", "--no-gpg-sign", "-m", "seed"])
    head_sha = run_git!(["-C", repo_dir, "rev-parse", "HEAD"]) |> String.trim()

    on_exit(fn ->
      File.rm_rf(repo_dir)
      # The executor's `after` block cleans up its own worktree under
      # `~/.foreman/worktrees/<project_id>/<run_id>/`; the `on_exit`
      # here wipes the working dir on the daemon cwd side only.
    end)

    relative_trd = "TRD-GATE.md"

    workflow_snapshot = %{
      run_id: run_id,
      workflow_name: "implement-trd-beads",
      workflow_digest: "test-digest",
      implementation: %{
        project_root: repo_dir,
        source_revision: head_sha,
        implementation_key: String.duplicate("a", 64),
        trd_path: relative_trd,
        beads_database_path: database_path
      },
      phases: [
        %{
          name: :implement_trd_beads,
          action: :command,
          command: "/skill:ensemble-full-implement-trd-beads --foreman",
          required_file: "trd_path",
          index: 1,
          phase_id: Identity.phase_id(run_id, 1),
          artifact_template: %{
            path: Path.join([artifact_dir, "{run_id}-{task_id}-implement.md"])
          },
          context: %{"script_key" => script_key, "write_paths" => [relative_trd]},
          worktree: %{
            enabled: true,
            path: "implement-trd-beads",
            cleanup: "always"
          }
        }
      ]
    }

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    seed_feature_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      database_path
    )

    expect(BrRunnerMock, :cmd, 1, fn {:update, %{flags: ["--claim", task_id]}}, _cfg, opts ->
      send(test_pid, {:runner_cmd, :claim})
      assert opts == [timeout_ms: 30_000]
      claim_payload_json(task_id)
    end)

    expect(BrRunnerMock, :cmd, 1, fn {:close, %{id: ^task_id}}, _cfg, opts ->
      send(test_pid, {:runner_cmd, :close})
      assert opts == [timeout_ms: 30_000]
      close_payload_json(task_id)
    end)

    task = ProjectionStore.task_projection(task_id)

    run_pid =
      start_supervised!(%{
        id: {RunExecutor, run_id},
        start: {RunExecutor, :start_link, [run_id, task]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      })

    assert is_pid(run_pid)

    # Adapter received the context. `working_directory` is the worktree path.
    assert_receive {:adapter_execute, _prompt, context}, @poll_timeout_ms
    working_directory = context["working_directory"]
    assert is_binary(working_directory) and working_directory != ""

    assert String.contains?(working_directory, run_id),
           "expected working_directory to be inside the worktree tree, got: #{working_directory}"

    # The TestAdapter materializes the relative path on disk inside the
    # worktree BEFORE returning, which is what a real agent would do.
    assert File.regular?(Path.join(working_directory, relative_trd))

    # Non-plan run, this time with an active worktree: still no planning
    # context, so still no plan variables.
    assert_receive {:adapter_env, env}, @poll_timeout_ms
    assert env["FOREMAN_WORKTREE_PATH"] == working_directory
    refute Map.has_key?(env, "FOREMAN_TASK_TITLE")
    refute Map.has_key?(env, "FOREMAN_SOURCE_PRD_PATH")

    phase_id = Identity.phase_id(run_id, 1)

    {:ok, completed_phase} =
      poll_until(
        fn ->
          case ProjectionStore.phase_projection(phase_id) do
            %{status: "completed"} = phase -> {:ok, phase}
            other -> {:error, other}
          end
        end,
        "phase completed"
      )

    assert completed_phase.status == "completed"

    failure_reason =
      (Map.get(completed_phase, :failure_reason) || Map.get(completed_phase, "failure_reason"))
      |> to_string()

    # Belt-and-suspenders: the regression's distinctive failure shape
    # must NOT appear in the projection.
    refute failure_reason =~ "required_file_missing"
    refute failure_reason =~ "required_file_unknown_key"

    # Wait for the close dispatch before exit so Mox sees the close expect fire.
    assert_receive {:runner_cmd, :close}, @poll_timeout_ms
  end

  test "initialization failure retries run.fail dispatch instead of silently stopping" do
    # The dispatch-daemon trap this guards: if the very first `run.fail`
    # dispatch inside `emit_phase_failure` returns an error, the original
    # kickoff handler used to return `{:stop, :normal, state}` from the
    # `:kickoff` path with the reason dropped on the floor. The run
    # stayed non-terminal until StuckDetector's 15-min idle threshold
    # fired, leaving the task wedged and unblocking `task.retry` only
    # much later. The fix routes every silent-stop path through a
    # bounded-retry helper that persists the executor across transient
    # dispatcher blips and exits `:normal` once the run reaches
    # terminal state.
    #
    # We exercise the path via a `:bash` phase action — `validate_phase_action/2`
    # rejects it with `{:error, {:unsupported_phase_action, :bash}}` —
    # and inject a one-shot failure on the FIRST `run.fail` dispatch
    # via the test seam, so the second attempt inside the retry helper
    # succeeds.
    expect_schema_boot_fetches()
    start_supervised!(JsonSchemaCache)

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")

    run_id =
      "run-" <> Base.encode16(:crypto.hash(:sha256, "task-#{task_id}-approve"), case: :lower)

    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))

    # Inject a one-shot failure: the first `run.fail` dispatch returns
    # `{:error, :test_injected_dispatch_failure}` (drives the retry
    # path); every subsequent call passes through to the real
    # `dispatch_system_command`.
    Application.put_env(
      :foreman_server,
      :run_executor_test_dispatch_attempt_count,
      0
    )

    Application.put_env(
      :foreman_server,
      :run_executor_test_dispatch_failure,
      fn attempt_count ->
        send(test_pid, {:dispatch_injection_attempt, attempt_count})

        case attempt_count do
          1 -> {:error, :test_injected_dispatch_failure}
          _ -> :passthrough
        end
      end
    )

    on_exit(fn ->
      Application.delete_env(:foreman_server, :run_executor_test_dispatch_failure)
      Application.delete_env(:foreman_server, :run_executor_test_dispatch_attempt_count)
    end)

    # `:bash` is an unsupported phase action — `validate_phase_action`
    # rejects it deterministically without needing a real worktree or
    # adapter invocation.
    workflow_snapshot = %{
      run_id: run_id,
      workflow_name: "implement-trd-beads",
      workflow_digest: "test-digest",
      phases: [
        %{
          name: :will_never_run,
          action: :bash,
          command: "echo hello",
          required_file: nil,
          index: 1,
          phase_id: Identity.phase_id(run_id, 1),
          artifact_template: %{
            path: Path.join([artifact_dir, "{run_id}-{task_id}-never.md"])
          },
          context: %{"script_key" => script_key}
        }
      ]
    }

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    seed_feature_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      database_path
    )

    # Only the claim Mox expect is needed: `maybe_fail_task` is NEVER
    # reached because the injected first failure short-circuits
    # `emit_phase_failure`'s `with` chain before the task-level
    # dispatch.
    expect(BrRunnerMock, :cmd, 1, fn {:update, %{flags: ["--claim", task_id]}}, _cfg, opts ->
      send(test_pid, {:runner_cmd, :claim})
      assert opts == [timeout_ms: 30_000]
      claim_payload_json(task_id)
    end)

    task = ProjectionStore.task_projection(task_id)

    # `restart: :temporary` so a `:normal` exit (the desired outcome)
    # does not loop, and any other abnormal exit is observable.
    run_pid =
      start_supervised!(%{
        id: {RunExecutor, run_id},
        start: {RunExecutor, :start_link, [run_id, task]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      })

    assert is_pid(run_pid)

    # The injection fires at least twice: once inside `emit_phase_failure`
    # (call 1, returns error) and once inside `finalize_terminal_dispatch`
    # (call 2, returns `:passthrough`). Subsequent dispatches would be
    # `:run_terminal` errors from the aggregate and not invoke the
    # injection because they short-circuit at `dispatch_run_fail`
    # returning `:ok` (or `:run_terminal`).
    assert_receive {:dispatch_injection_attempt, 1}, @poll_timeout_ms
    assert_receive {:dispatch_injection_attempt, 2}, @poll_timeout_ms

    # Run reached terminal `failed` via the second successful `run.fail`.
    {:ok, failed_run} =
      poll_until(
        fn ->
          case ProjectionStore.run(run_id) do
            %{status: "failed"} = run -> {:ok, run}
            other -> {:error, other}
          end
        end,
        "run failed"
      )

    # Once the run is terminal, the executor must have exited normally.
    # With `restart: :temporary`, a `:normal` exit removes the child
    # from the supervisor cleanly. Poll for `Process.alive?/1` to
    # return false rather than `Process.monitor/1` — the latter races
    # with the supervisor's registry cleanup when the exit happens
    # during the test's `assert_receive`/`poll_until` windows.
    poll_until(
      fn ->
        if Process.alive?(run_pid), do: {:error, :still_alive}, else: {:ok, :exited}
      end,
      "executor exit"
    )

    assert failed_run.status == "failed"
  end

  ### Setup helpers

  defp start_schema_cache! do
    case Process.whereis(@cache_name) do
      nil -> start_supervised!({JsonSchemaCache, name: @cache_name})
      _pid -> :ok
    end
  end

  defp stop_schema_cache do
    case Process.whereis(@cache_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp ensure_started(child, name) do
    if Process.whereis(name) do
      :ok
    else
      case child do
        module when is_atom(module) ->
          _ = start_supervised(module)

        other ->
          _ = start_supervised(other)
      end

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

  defp previous_backend_adapter do
    configured =
      Application.get_env(:foreman_server, :agent_runtime, [])
      |> Keyword.get(:adapters, [])
      |> Enum.find_value(fn
        adapter when is_atom(adapter) ->
          name = adapter.name()

          case AdapterCatalog.lookup(name) do
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

  defp unique_id(prefix) do
    "#{prefix}-run-executor-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp unique_database_path(script_key) do
    Path.join(System.tmp_dir!(), "#{script_key}.db")
  end

  # A real repo with a commit at HEAD: the default-on worktree runs
  # `git worktree add` against the project's registered path, and the
  # discovery gate runs `git status` inside the worktree it produces.
  defp init_plan_repo!(project_id) do
    repo_dir = Path.join(System.tmp_dir!(), "foreman-plan-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo_dir)
    File.mkdir_p!(repo_dir)
    run_git!(["-C", repo_dir, "init", "--initial-branch=main"])
    run_git!(["-C", repo_dir, "config", "user.email", "plan@test"])
    run_git!(["-C", repo_dir, "config", "user.name", "Plan Test"])
    File.write!(Path.join(repo_dir, "README.md"), "seed")
    run_git!(["-C", repo_dir, "add", "."])
    run_git!(["-C", repo_dir, "commit", "--no-gpg-sign", "-m", "seed"])

    on_exit(fn ->
      File.rm_rf(repo_dir)
      File.rm_rf(Path.join([System.user_home!(), ".foreman/worktrees", project_id]))
    end)

    repo_dir
  end

  # Drive one plan phase gated on `planning.prd_path` whose agent writes
  # exactly `write_paths` inside its worktree, and return the ids needed to
  # assert on the outcome. The phase's fate is entirely decided by how many
  # new documents appear under `docs/PRD`.
  defp run_plan_capture_phase!(write_paths: write_paths) do
    expect_schema_boot_fetches()
    start_supervised!(JsonSchemaCache)

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")

    run_id =
      "run-" <> Base.encode16(:crypto.hash(:sha256, "task-#{task_id}-approve"), case: :lower)

    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    repo_dir = init_plan_repo!(project_id)

    workflow_snapshot = %{
      run_id: run_id,
      workflow_name: "plan",
      workflow_digest: "test-digest",
      phases: [
        %{
          name: :create_prd,
          action: :command,
          command: "/skill:ensemble-full-create-prd --foreman",
          required_file: "planning.prd_path",
          index: 1,
          phase_id: Identity.phase_id(run_id, 1),
          artifact_template: %{
            path: Path.join([artifact_dir, "{run_id}-{task_id}-create_prd.md"])
          },
          context: %{"script_key" => script_key, "write_paths" => write_paths}
        }
      ]
    }

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    seed_plan_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      database_path,
      repo_dir
    )

    expect(BrRunnerMock, :cmd, 1, fn {:update, %{flags: ["--claim", task_id]}}, _cfg, _opts ->
      send(test_pid, {:runner_cmd, :claim})
      claim_payload_json(task_id)
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, _cfg, _opts ->
      send(test_pid, {:runner_cmd, :reopen, request})
      claim_payload_json(task_id)
    end)

    task = ProjectionStore.task_projection(task_id)

    run_pid =
      start_supervised!(%{
        id: {RunExecutor, run_id},
        start: {RunExecutor, :start_link, [run_id, task]},
        restart: :temporary,
        shutdown: 5_000,
        type: :worker
      })

    assert is_pid(run_pid)
    assert_receive {:adapter_execute, _prompt, _context}, @poll_timeout_ms

    %{run_id: run_id, phase_id: Identity.phase_id(run_id, 1)}
  end

  defp await_phase_failure!(phase_id) do
    {:ok, failed_phase} =
      poll_until(
        fn ->
          case ProjectionStore.phase_projection(phase_id) do
            %{status: "failed"} = phase -> {:ok, phase}
            other -> {:error, other}
          end
        end,
        "phase failed"
      )

    reason = Map.get(failed_phase, :failure_reason) || Map.get(failed_phase, "failure_reason")
    assert is_binary(reason)
    reason
  end

  # Wait for the RUN (not just the phase) to reach its terminal state, then
  # for the provider reopen the terminal dispatch triggers.
  # Dispatcher.handle_run_terminated/3 and the provider call both react to
  # the run's own failure event asynchronously; without both waits the test
  # can finish first, and on_exit's kill_and_restart_dispatcher then kills
  # Dispatcher mid-dispatch, leaving BrRunnerMock under-invoked and failing
  # verification on a race rather than on behaviour.
  defp await_run_failure!(run_id) do
    assert {:ok, %{status: "failed"}} =
             poll_until(
               fn ->
                 case ProjectionStore.run(run_id) do
                   %{status: "failed"} = run -> {:ok, run}
                   other -> {:error, other}
                 end
               end,
               "run failed"
             )

    assert_receive {:runner_cmd, :reopen, _request}, @poll_timeout_ms
  end

  defp seed_plan_project_task_and_run!(
         project_id,
         task_id,
         run_id,
         workflow_snapshot,
         database_path,
         project_path \\ System.tmp_dir!()
       ) do
    dispatch_system!("project.register", "project:#{project_id}", %{
      project_id: project_id,
      name: "Plan #{project_id}",
      path: project_path,
      task_provider: %{
        "provider" => "beads",
        "config" => %{"database_path" => database_path}
      }
    })

    :ok =
      TaskProviderRegistry.register_for_project(project_id, BeadsAdapter, %{
        "database_path" => database_path
      })

    approval_id = unique_id("approval")

    # Beads rejects task_type "plan" with INVALID_ISSUE_TYPE (it accepts
    # task|bug|feature|epic|chore|docs|question), so a real plan run on a
    # beads-backed project always carries a domain issue type plus
    # workflow_type: "plan". PlanContext gates on the workflow, not the type.
    dispatch_system!("task.create", "task:#{task_id}", %{
      task_id: task_id,
      project_id: project_id,
      task_type: "feature",
      workflow_type: "plan",
      external_id: task_id,
      title: "Plan #{task_id}",
      description: "Plan task description for #{task_id}"
    })

    dispatch_system!("task.approve", "task:#{task_id}", %{
      task_id: task_id,
      approval_id: approval_id,
      approved_by: "run-executor-command-test",
      approved_at: "2026-08-08T00:00:00Z",
      run_id: run_id,
      workflow_snapshot: workflow_snapshot
    })

    dispatch_system!("task.dispatch", "task:#{task_id}", %{task_id: task_id})

    assert {:ok, _} =
             RunAdmission.start(project_id, %{
               run_id: run_id,
               task_id: task_id,
               project_id: project_id,
               approval_id: approval_id,
               workflow_snapshot: workflow_snapshot,
               phase_specs: Map.get(workflow_snapshot, :phases, [])
             })
  end

  defp seed_feature_project_task_and_run!(
         project_id,
         task_id,
         run_id,
         workflow_snapshot,
         database_path
       ) do
    dispatch_system!("project.register", "project:#{project_id}", %{
      project_id: project_id,
      name: "Feature #{project_id}",
      path: System.tmp_dir!(),
      task_provider: %{
        "provider" => "beads",
        "config" => %{"database_path" => database_path}
      }
    })

    :ok =
      TaskProviderRegistry.register_for_project(project_id, BeadsAdapter, %{
        "database_path" => database_path
      })

    approval_id = unique_id("approval")

    impl_key =
      Map.get(workflow_snapshot, :implementation, %{})
      |> Map.get(:implementation_key, "feature-key-#{task_id}")

    dispatch_system!("task.create", "task:#{task_id}", %{
      task_id: task_id,
      project_id: project_id,
      task_type: "feature",
      external_id: task_id,
      title: "Feature #{task_id}",
      description: "Feature task description for #{task_id}",
      implementation_key: impl_key
    })

    dispatch_system!("task.approve", "task:#{task_id}", %{
      task_id: task_id,
      approval_id: approval_id,
      approved_by: "run-executor-command-test",
      approved_at: "2026-08-08T00:00:00Z",
      run_id: run_id,
      workflow_snapshot: workflow_snapshot
    })

    dispatch_system!("task.dispatch", "task:#{task_id}", %{task_id: task_id})

    assert {:ok, _} =
             RunAdmission.start(project_id, %{
               run_id: run_id,
               task_id: task_id,
               project_id: project_id,
               approval_id: approval_id,
               workflow_snapshot: workflow_snapshot,
               phase_specs: Map.get(workflow_snapshot, :phases, [])
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

  defp poll_until(fun, label) do
    deadline = System.monotonic_time(:millisecond) + @poll_timeout_ms
    do_poll(fun, deadline, label)
  end

  defp do_poll(fun, deadline, label) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, _} ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("timeout waiting for #{label}")
        else
          Process.sleep(25)
          do_poll(fun, deadline, label)
        end
    end
  end

  defp expect_schema_boot_fetches do
    expect(BrRunnerMock, :cmd, 4, fn {:schema, %{schema: schema_name}}, %{}, [] ->
      {:ok, %{stdout: Jason.encode!(schema_document(schema_name))}}
    end)
  end

  defp schema_document("ready-issue") do
    %{
      "type" => "object",
      "required" => [
        "id",
        "title",
        "status",
        "priority",
        "dependencies",
        "assignee",
        "description",
        "notes",
        "design",
        "labels",
        "metadata"
      ],
      "properties" => %{
        "id" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "status" => %{"type" => "string"},
        "priority" => %{"type" => "integer"},
        "dependencies" => %{"type" => "array"},
        "assignee" => %{"type" => ["string", "null"]},
        "description" => %{"type" => ["string", "null"]},
        "notes" => %{"type" => ["string", "null"]},
        "design" => %{"type" => ["string", "null"]},
        "labels" => %{"type" => "array"},
        "metadata" => %{"type" => "object"}
      }
    }
  end

  defp schema_document("issue-details") do
    %{
      "type" => "object",
      "required" => ["id", "description"],
      "properties" => %{
        "id" => %{"type" => "string"},
        "description" => %{"type" => "string"}
      }
    }
  end

  defp schema_document("error") do
    %{
      "type" => "object",
      "required" => ["code", "message"],
      "properties" => %{
        "code" => %{"type" => "string"},
        "message" => %{"type" => "string"}
      }
    }
  end

  defp schema_document("commands") do
    %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string"}
      }
    }
  end

  defp kill_and_restart_dispatcher(_dispatcher) do
    app_sup = Process.whereis(ForemanServer.Application)

    if app_sup do
      :ok = Supervisor.terminate_child(app_sup, ForemanServer.Workflow.Dispatcher)

      {:ok, _new_dispatcher} =
        Supervisor.restart_child(app_sup, ForemanServer.Workflow.Dispatcher)
    end
  end

  # Run a git command and return combined stdout/stderr. Raises on
  # non-zero exit so test failures surface immediately with the git
  # output that caused them.
  defp run_git!(args) do
    {output, 0} = System.cmd("git", args, stderr_to_stdout: true)
    output
  end

  defp claim_payload_json(task_id) do
    {:ok,
     %{
       stdout:
         Jason.encode!([
           %{
             "id" => task_id,
             "title" => "Feature #{task_id}",
             "status" => "in_progress",
             "priority" => 2,
             "dependencies" => [],
             "assignee" => "foreman-runner",
             "description" => "Feature task description",
             "notes" => nil,
             "design" => nil,
             "labels" => ["workflow", "in_progress"],
             "metadata" => %{"provider_id" => "beads", "source" => "br update"}
           }
         ]),
       stderr: "",
       exit_code: 0
     }}
  end

  defp close_payload_json(task_id) do
    {:ok,
     %{
       stdout:
         Jason.encode!([
           %{
             "id" => task_id,
             "title" => "Feature #{task_id}",
             "status" => "closed",
             "priority" => 1,
             "dependencies" => [],
             "assignee" => nil,
             "description" => nil,
             "notes" => nil,
             "design" => nil,
             "labels" => [],
             "metadata" => %{}
           }
         ]),
       stderr: "",
       exit_code: 0
     }}
  end
end
