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

    previous_pi_adapter =
      case AdapterCatalog.lookup(:pi) do
        {:ok, module} -> module
        {:error, :not_found} -> nil
      end

    ensure_test_adapter_registered(previous_pi_adapter)

    on_exit(fn ->
      restore_pi_adapter(previous_pi_adapter)
    end)

    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    RunSlotsReset.reset!()
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

  test "command: phase forwards slash command at byte zero and requiredFile gate fails when the file is missing" do
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
          context: %{"script_key" => script_key}
        }
      ]
    }

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    seed_plan_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      database_path
    )

    # PlanContext requires an existing project directory. System.tmp_dir!() is
    # always present, so the seeded project's path is a real directory.
    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", task_id]}}
      assert opts == [timeout_ms: 30_000]

      assert (Map.get(runner_project_config, :database_path) ||
                Map.get(runner_project_config, "database_path")) == database_path

      send(test_pid, {:runner_cmd, :claim, request})

      {:ok,
       %{
         stdout:
           Jason.encode!(%{
             "id" => task_id,
             "title" => "Plan #{task_id}",
             "status" => "in_progress",
             "priority" => 2,
             "dependencies" => [],
             "assignee" => "foreman-runner",
             "description" => "Plan task description",
             "notes" => nil,
             "design" => nil,
             "labels" => ["workflow", "in_progress"],
             "metadata" => %{"provider_id" => "beads", "source" => "br update"}
           }),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, _runner_project_config, opts ->
      assert opts == [timeout_ms: 30_000]
      send(test_pid, {:runner_cmd, :reopen, request})

      {:ok,
       %{
         stdout:
           Jason.encode!(%{
             "id" => task_id,
             "title" => "Plan #{task_id}",
             "status" => "open",
             "priority" => 2,
             "dependencies" => [],
             "assignee" => nil,
             "description" => "Plan task description",
             "notes" => nil,
             "design" => nil,
             "labels" => ["workflow", "open"],
             "metadata" => %{"provider_id" => "beads", "source" => "br reopen"}
           }),
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

    # Adapter must receive the slash command at byte zero.
    assert_receive {:adapter_execute, prompt, context}, @poll_timeout_ms
    assert is_binary(prompt)

    assert String.starts_with?(prompt, "/skill:ensemble-full-create-prd"),
           "expected prompt to begin with the slash command, got: #{inspect(String.slice(prompt, 0, 80))}"

    # PlanContext fields flowed through base_context into the adapter context.
    assert context["run_id"] == run_id
    assert context["task_id"] == task_id
    assert is_binary(context["working_directory"]) and context["working_directory"] != ""
    assert is_map(context["planning"])
    assert is_binary(context["planning"]["prd_path"])
    assert is_binary(context["planning"]["trd_path"])
    assert is_binary(context["planning"]["slug"])
    assert is_integer(context["planning"]["document_year"])

    # The resolved requiredFile path is the planning.prd_path context value.
    expected_path = context["planning"]["prd_path"]
    assert String.ends_with?(expected_path, ".md")
    phase_id = Identity.phase_id(run_id, 1)

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

    assert failed_phase.status == "failed"

    failure_reason =
      Map.get(failed_phase, :failure_reason) || Map.get(failed_phase, "failure_reason")

    assert is_binary(failure_reason)
    assert failure_reason =~ "required_file_missing"
    assert failure_reason =~ "planning.prd_path"
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

  defp ensure_test_adapter_registered(previous_pi_adapter) do
    case previous_pi_adapter do
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

  defp restore_pi_adapter(previous_pi_adapter) do
    case previous_pi_adapter do
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

  defp unique_id(prefix) do
    "#{prefix}-run-executor-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp unique_database_path(script_key) do
    Path.join(System.tmp_dir!(), "#{script_key}.db")
  end

  defp seed_plan_project_task_and_run!(
         project_id,
         task_id,
         run_id,
         workflow_snapshot,
         database_path
       ) do
    dispatch_system!("project.register", "project:#{project_id}", %{
      project_id: project_id,
      name: "Plan #{project_id}",
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

    dispatch_system!("task.create", "task:#{task_id}", %{
      task_id: task_id,
      project_id: project_id,
      task_type: "plan",
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
