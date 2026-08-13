defmodule ForemanServer.Workflow.RunExecutorTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.{
    AgentRuntime,
    CommandGateway,
    EventStore,
    Identity,
    ProjectionStore,
    RunAdmission
  }

  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.TaskProviders.{BeadsAdapter, BrRunnerMock, JsonSchemaCache, SystemBrRunner}
  alias ForemanServer.Workflow.RunExecutor

  @cache_name :foreman_server_json_schema_cache
  @route_ok_event [:foreman_server, :task_provider, :registry, :route, :ok]
  @poll_timeout_ms 8_000
  @run_executor_source "lib/foreman_server/workflow/run_executor.ex"

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

    def take(script_key, field, default) do
      Agent.get_and_update(__MODULE__, fn state ->
        script = Map.get(state, script_key, %{})
        values = Map.get(script, field, [])

        {result, rest} =
          case values do
            [value | tail] -> {value, tail}
            [] -> {default, []}
          end

        next_script = Map.put(script, field, rest)
        {result, Map.put(state, script_key, next_script)}
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
        supported_contexts: [:implement, :test]
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def execute(%{prompt: prompt, context: context}, opts) do
      script_key = Map.fetch!(context, "script_key")
      env = Keyword.get(opts, :env, %{})

      if pid = LifecycleStore.test_pid(script_key) do
        send(pid, {:adapter_execute, prompt, context})

        if map_size(env) > 0 do
          send(pid, {:adapter_env, env})
        end
      end

      LifecycleStore.take(script_key, :adapter_results, {:ok, "artifact body", %{}})
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

    stub(BrRunnerMock, :cmd, fn request, project_config, opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call: #{inspect({request, project_config, opts})}")
    end)

    temp_dir =
      Path.join(
        System.tmp_dir!(),
        "run_executor_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(temp_dir)
    write_fake_br!(temp_dir, default_fake_br_body())

    original_path = System.get_env("PATH") || ""
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_task_provider)
      System.put_env("PATH", original_path)
      stop_schema_cache()
      File.rm_rf!(temp_dir)
    end)

    {:ok, temp_dir: temp_dir}
  end

  test "start phase claims before dispatch and completes on TaskExecutionCompleted", %{
    temp_dir: temp_dir
  } do
    start_schema_cache!()

    {collector, ref} = start_telemetry_collector([@route_ok_event])

    on_exit(fn ->
      :telemetry.detach(ref)
      stop_telemetry_collector(collector)
    end)

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    workflow_snapshot = %{phases: [phase_spec(script_key, artifact_dir)]}

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    seed_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      project_task_provider(database_path)
    )

    register_project!(project_id, database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", task_id]}}
      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["update", "--db", database_path, "--claim", task_id, "--json"]
      )

      send(test_pid, {:runner_cmd, :claim, request, runner_project_config, opts})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "in_progress", %{
               "assignee" => "foreman-runner",
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:close, %{id: task_id}}
      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["close", "--db", database_path, task_id, "--json"]
      )

      send(test_pid, {:runner_cmd, :complete, request, runner_project_config, opts})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "closed", %{
               "metadata" => %{"provider_id" => "beads", "source" => "br close"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert is_pid(start_run_executor!(run_id, task_id))

    assert {:runner_cmd, :claim, {:update, %{flags: ["--claim", ^task_id]}}, _, _} =
             receive_message()

    assert {:adapter_execute, "Run phase implement", context} = receive_message()
    assert context["script_key"] == script_key
    assert context["phase_id"] == Identity.phase_id(run_id, 1)
    assert context["run_id"] == run_id
    assert context["task_id"] == task_id

    artifact_path = Path.join(artifact_dir, "#{run_id}-#{task_id}.md")

    assert {:runner_cmd, :complete, {:close, %{id: ^task_id}}, _, _} = receive_message()

    assert %{status: "closed"} =
             poll_until(
               fn ->
                 case ProjectionStore.task_projection(task_id) do
                   %{status: "closed"} = task -> {:ok, task}
                   other -> {:error, other}
                 end
               end,
               "task closed"
             )

    assert %{status: "completed"} =
             poll_until(
               fn ->
                 case ProjectionStore.run(run_id) do
                   %{status: "completed"} = run -> {:ok, run}
                   other -> {:error, other}
                 end
               end,
               "run completed"
             )

    phase_id = Identity.phase_id(run_id, 1)

    assert %{status: "completed", artifact: artifact} =
             poll_until(
               fn ->
                 case ProjectionStore.phase_projection(phase_id) do
                   %{status: "completed"} = phase -> {:ok, phase}
                   other -> {:error, other}
                 end
               end,
               "phase completed"
             )

    assert artifact.path == artifact_path
    assert artifact.bytes == byte_size("artifact body")
    assert artifact.sha256 == Identity.sha256("artifact body")
    assert File.read!(artifact_path) == "artifact body"
    assert count_task_events(task_id, "TaskExecutionCompleted") == 1

    transitions =
      poll_until(
        fn ->
          transitions = route_transitions(collector, BeadsAdapter)

          if Enum.count(transitions, &(&1 == :claim)) == 1 and
               Enum.count(transitions, &(&1 == :close)) == 1 do
            {:ok, transitions}
          else
            {:error, transitions}
          end
        end,
        "claim and close route telemetry"
      )

    assert transitions == [:claim, :close]
  end

  test "failure path invokes fail on TaskExecutionFailed with deterministic default transition comment",
       %{
         temp_dir: temp_dir
       } do
    start_schema_cache!()

    {collector, ref} = start_telemetry_collector([@route_ok_event])

    on_exit(fn ->
      :telemetry.detach(ref)
      stop_telemetry_collector(collector)
    end)

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    workflow_snapshot = %{phases: [phase_spec(script_key, artifact_dir)]}
    artifact_path = Path.join(artifact_dir, "#{run_id}-#{task_id}.md")
    expected_comment = "foreman-run:#{run_id}:#{artifact_path}"

    LifecycleStore.put(script_key, %{test_pid: test_pid, adapter_results: [{:error, :boom}]})

    seed_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      project_task_provider(database_path)
    )

    register_project!(project_id, database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", task_id]}}
      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        ["update", "--db", database_path, "--claim", task_id, "--json"]
      )

      send(test_pid, {:runner_cmd, :claim, request, runner_project_config, opts})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "in_progress", %{
               "assignee" => "foreman-runner",
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    task_id,
                    "--status",
                    "open",
                    "--transition-comment",
                    expected_comment
                  ],
                  database_path: database_path
                }}

      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]

      assert_translated_argv(
        temp_dir,
        request,
        runner_project_config,
        [
          "update",
          "--db",
          database_path,
          task_id,
          "--status",
          "open",
          "--transition-comment",
          expected_comment,
          "--json"
        ]
      )

      send(test_pid, {:runner_cmd, :fail, request, runner_project_config, opts})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "open", %{
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    assert is_pid(start_run_executor!(run_id, task_id))

    assert {:runner_cmd, :claim, {:update, %{flags: ["--claim", ^task_id]}}, _, _} =
             receive_message()

    assert {:adapter_execute, "Run phase implement", _context} = receive_message()

    assert {:runner_cmd, :fail,
            {:update,
             %{
               flags: [
                 ^task_id,
                 "--status",
                 "open",
                 "--transition-comment",
                 ^expected_comment
               ]
             }}, _, _} = receive_message()

    assert %{status: "failed"} =
             poll_until(
               fn ->
                 case ProjectionStore.task_projection(task_id) do
                   %{status: "failed"} = task -> {:ok, task}
                   other -> {:error, other}
                 end
               end,
               "task failed"
             )

    assert count_task_events(task_id, "TaskExecutionFailed") == 1

    transitions =
      poll_until(
        fn ->
          transitions = route_transitions(collector, BeadsAdapter)

          if Enum.count(transitions, &(&1 == :claim)) == 1 and
               Enum.any?(transitions, &(&1 in [:reopen, :fail])) do
            {:ok, transitions}
          else
            {:error, transitions}
          end
        end,
        "failure route telemetry"
      )

    assert :claim in transitions
    assert Enum.any?(transitions, &(&1 in [:reopen, :fail]))
  end

  test "complete/4 is idempotent when the provider reports ALREADY_CLOSED" do
    start_schema_cache!()

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    database_path = unique_database_path(unique_id("script"))
    artifact_path = "/artifacts/#{run_id}/#{task_id}.md"

    seed_project!(project_id, project_task_provider(database_path))
    register_project!(project_id, database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:close, %{id: task_id}}
      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]
      send(test_pid, {:runner_cmd, :complete, request, runner_project_config, opts})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "closed", %{
               "metadata" => %{"provider_id" => "beads", "source" => "br close"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    stderr =
      Jason.encode!(%{
        "code" => "ALREADY_CLOSED",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:close, %{id: task_id}}
      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]
      send(test_pid, {:runner_cmd, :complete, request, runner_project_config, opts})
      {:error, %{stdout: "", stderr: stderr, exit_code: 9}}
    end)

    assert {:ok, %Issue{status: "closed", id: ^task_id}} =
             RunExecutor.complete(project_id, task_id, run_id, artifact_path)

    assert_receive {:runner_cmd, :complete, {:close, %{id: ^task_id}}, _, _}, 1_000

    assert {:ok, :already_terminal} =
             RunExecutor.complete(project_id, task_id, run_id, artifact_path)

    assert_receive {:runner_cmd, :complete, {:close, %{id: ^task_id}}, _, _}, 1_000
  end

  test "second finalize after ALREADY_CLOSED does not emit a duplicate TaskExecutionCompleted event" do
    start_schema_cache!()

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    workflow_snapshot = %{phases: [phase_spec(script_key, artifact_dir)]}

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    seed_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      project_task_provider(database_path)
    )

    register_project!(project_id, database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", task_id]}}
      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]
      send(test_pid, {:runner_cmd, :claim, request, runner_project_config, opts})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "in_progress", %{
               "assignee" => "foreman-runner",
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:close, %{id: task_id}}
      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]
      send(test_pid, {:runner_cmd, :complete, request, runner_project_config, opts})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "closed", %{
               "metadata" => %{"provider_id" => "beads", "source" => "br close"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    stderr =
      Jason.encode!(%{
        "code" => "ALREADY_CLOSED",
        "message" => "ignored envelope message",
        "hint" => "ignored envelope hint",
        "retryable?" => false
      })

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:close, %{id: task_id}}
      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]
      send(test_pid, {:runner_cmd, :complete, request, runner_project_config, opts})
      {:error, %{stdout: "", stderr: stderr, exit_code: 9}}
    end)

    assert is_pid(start_run_executor!(run_id, task_id))

    assert {:runner_cmd, :claim, {:update, %{flags: ["--claim", ^task_id]}}, _, _} =
             receive_message()

    assert {:adapter_execute, "Run phase implement", _context} = receive_message()
    assert {:runner_cmd, :complete, {:close, %{id: ^task_id}}, _, _} = receive_message()

    assert %{status: "closed"} =
             poll_until(
               fn ->
                 case ProjectionStore.task_projection(task_id) do
                   %{status: "closed"} = task -> {:ok, task}
                   other -> {:error, other}
                 end
               end,
               "task closed before second finalize"
             )

    assert count_task_events(task_id, "TaskExecutionCompleted") == 1

    assert :ok = RunExecutor.advance_to(run_id, 0)

    assert_receive {:runner_cmd, :complete, {:close, %{id: ^task_id}}, _, _}, 1_000

    assert 1 =
             poll_until(
               fn ->
                 count = count_task_events(task_id, "TaskExecutionCompleted")

                 if count == 1 do
                   {:ok, count}
                 else
                   {:error, count}
                 end
               end,
               "single TaskExecutionCompleted event"
             )
  end

  test "runner source resolves providers through Registry.route/2 and never directly invokes reopen or BeadsAdapter transitions" do
    source = File.read!(@run_executor_source)

    assert source =~ "TaskProviderRegistry.route(transition, {project_id, database_path})"
    refute source =~ "BeadsAdapter.claim("
    refute source =~ "BeadsAdapter.complete("
    refute source =~ "BeadsAdapter.fail("
    refute source =~ "BeadsAdapter.reopen("
    refute Regex.match?(~r/\.\s*reopen\(/, source)
  end

  test "RunExecutor.claim/3 resolves BeadsAdapter via Registry.route for short-name providers" do
    start_schema_cache!()

    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")
    database_path = unique_database_path(unique_id("db"))

    seed_project!(project_id, project_task_provider(database_path))
    register_project!(project_id, database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", task_id]}}
      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]

      send(test_pid, {:claim_cmd, request, runner_project_config})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "in_progress", %{
               "assignee" => "foreman-runner",
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    result = RunExecutor.claim(project_id, task_id, "foreman-runner")

    refute match?({:error, :task_provider_not_configured}, result)
    assert {:ok, %Issue{status: "in_progress", id: ^task_id}} = result

    assert_received {:claim_cmd, {:update, %{flags: ["--claim", ^task_id]}}, _project_config}
  end

  # --------------------------------------------------------------------
  # Worktree lifecycle integration (TRD-2026-3d41f677 Decisions 3/5/6/9)
  # Real git repo on disk, real git worktree add invoked through the
  # supervisor/code path; no mocks for filesystem or git.
  # --------------------------------------------------------------------

  test "worktree-enabled phase provisions a real git worktree and injects FOREMAN_* env" do
    start_schema_cache!()
    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("wt-script")
    database_path = unique_database_path(unique_id("db"))
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    File.mkdir_p!(artifact_dir)

    repo_path = make_bare_minimum_git_repo!(test_pid)
    source_revision = current_head_sha!(repo_path)
    on_exit_worktree_cleanup(repo_path, project_id, run_id)
    implementation_key = "deadbeef" <> Base.encode16(:crypto.hash(:md5, project_id), case: :lower)

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    phase = put_worktree(phase_spec(script_key, artifact_dir), %{enabled: true})

    seed_project_task_and_run_with_implementation!(
      project_id,
      task_id,
      run_id,
      %{phases: [phase]},
      project_task_provider(database_path),
      %{
        "project_root" => repo_path,
        "source_revision" => source_revision,
        "implementation_key" => implementation_key
      }
    )

    register_project!(project_id, database_path)
    claim_and_complete_expectations!(task_id)

    start_run_executor!(run_id, task_id)

    assert {:adapter_execute, "Run phase implement", _context} = receive_message(@poll_timeout_ms)
    assert {:adapter_env, env} = receive_message(@poll_timeout_ms)

    assert env["FOREMAN_WORKTREE"] == "1"
    assert env["FOREMAN_RUN_ID"] == run_id
    assert env["FOREMAN_SOURCE_REVISION"] == source_revision
    assert env["FOREMAN_IMPLEMENTATION_KEY"] == implementation_key

    worktree_path = env["FOREMAN_WORKTREE_PATH"]
    assert String.starts_with?(worktree_path, worktree_root_prefix())
    assert File.dir?(worktree_path)

    refute_received {:adapter_env, %{}}
    poll_run_completion!(run_id)
  end

  test "default cleanup: always removes the worktree after the phase succeeds" do
    start_schema_cache!()
    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("wt-cleanup-success")
    database_path = unique_database_path(unique_id("db"))
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    File.mkdir_p!(artifact_dir)

    repo_path = make_bare_minimum_git_repo!(test_pid)
    source_revision = current_head_sha!(repo_path)
    on_exit_worktree_cleanup(repo_path, project_id, run_id)
    LifecycleStore.put(script_key, %{test_pid: test_pid})

    phase = put_worktree(phase_spec(script_key, artifact_dir), %{enabled: true})

    seed_project_task_and_run_with_implementation!(
      project_id,
      task_id,
      run_id,
      %{phases: [phase]},
      project_task_provider(database_path),
      %{
        "project_root" => repo_path,
        "source_revision" => source_revision,
        "implementation_key" => "k1"
      }
    )

    register_project!(project_id, database_path)
    claim_and_complete_expectations!(task_id)

    start_run_executor!(run_id, task_id)

    assert {:adapter_execute, _prompt, _ctx} = receive_message(@poll_timeout_ms)
    assert {:adapter_env, env} = receive_message(@poll_timeout_ms)

    worktree_path = env["FOREMAN_WORKTREE_PATH"]
    assert File.dir?(worktree_path), "worktree exists during phase"

    poll_run_completion!(run_id)

    # Default `cleanup: always` removes the worktree after completion.
    # The exact cleanup implementation may not block the test process;
    # a short bounded wait observes the disk teardown.
    assert wait_until_cleaned(worktree_path, 500), "worktree #{worktree_path} was not cleaned"
  end

  test "cleanup: never preserves the worktree across the phase" do
    start_schema_cache!()
    test_pid = self()
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("wt-never")
    database_path = unique_database_path(unique_id("db"))
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    File.mkdir_p!(artifact_dir)

    repo_path = make_bare_minimum_git_repo!(test_pid)
    source_revision = current_head_sha!(repo_path)
    on_exit_worktree_cleanup(repo_path, project_id, run_id)
    LifecycleStore.put(script_key, %{test_pid: test_pid})

    phase =
      phase_spec(script_key, artifact_dir)
      |> put_worktree(%{
        enabled: true,
        branch: "foreman/#{run_id}/implement",
        cleanup: "never"
      })

    seed_project_task_and_run_with_implementation!(
      project_id,
      task_id,
      run_id,
      %{phases: [phase]},
      project_task_provider(database_path),
      %{
        "project_root" => repo_path,
        "source_revision" => source_revision,
        "implementation_key" => "k2"
      }
    )

    register_project!(project_id, database_path)
    claim_and_complete_expectations!(task_id)

    start_run_executor!(run_id, task_id)

    assert {:adapter_execute, _prompt, _ctx} = receive_message(@poll_timeout_ms)
    assert {:adapter_env, env} = receive_message(@poll_timeout_ms)
    worktree_path = env["FOREMAN_WORKTREE_PATH"]

    poll_run_completion!(run_id)

    # Give the test a short window in which cleanup could have run.
    Process.sleep(200)

    assert File.dir?(worktree_path),
           "cleanup: never must preserve worktree at #{worktree_path}"
  end

  # --------------------------------------------------------------------
  # Beads-managed TRD_SCOPE contract (TRD-2026-3d41f677 Decision 10)
  # When `beads_database_path` is frozen in plan_context, the executor MUST
  # export BEADS_DB + TRD_SCOPE alongside the FOREMAN_* keys; if the trd
  # path or the implementation key is malformed, provisioning MUST fail
  # closed at the worktree boundary.
  # --------------------------------------------------------------------

  test "beads-managed phase exports TRD_SCOPE = <trd-slug>-<first-12-of-impl-key>" do
    start_schema_cache!()
    test_pid = self()
    project_id = unique_id("project-beads")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("wt-beads-scope")
    database_path = unique_database_path(unique_id("db"))
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    File.mkdir_p!(artifact_dir)

    repo_path = make_bare_minimum_git_repo!(test_pid)
    source_revision = current_head_sha!(repo_path)
    on_exit_worktree_cleanup(repo_path, project_id, run_id)

    implementation_key =
      Base.encode16(:crypto.hash(:sha256, project_id <> run_id), case: :lower)

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    phase = put_worktree(phase_spec(script_key, artifact_dir), %{enabled: true})

    seed_project_task_and_run_with_implementation!(
      project_id,
      task_id,
      run_id,
      %{phases: [phase]},
      project_task_provider(database_path),
      %{
        "trd_path" => "docs/TRD/TRD-2026-beads-managed.md",
        "project_root" => repo_path,
        "source_revision" => source_revision,
        "implementation_key" => implementation_key,
        "beads_database_path" => database_path
      }
    )

    register_project!(project_id, database_path)
    claim_and_complete_expectations!(task_id)

    start_run_executor!(run_id, task_id)

    assert {:adapter_execute, _prompt, _ctx} = receive_message(@poll_timeout_ms)
    assert {:adapter_env, env} = receive_message(@poll_timeout_ms)

    assert env["FOREMAN_WORKTREE"] == "1"
    assert env["BEADS_DB"] == database_path

    expected_scope =
      "trd-2026-beads-managed-" <> binary_part(implementation_key, 0, 12)

    assert env["TRD_SCOPE"] == expected_scope

    poll_run_completion!(run_id)
  end

  test "beads-managed phase with malformed implementation_key fails closed at provisioning" do
    start_schema_cache!()
    test_pid = self()
    project_id = unique_id("project-beads-bad-key")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("wt-beads-bad-key")
    database_path = unique_database_path(unique_id("db"))
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    File.mkdir_p!(artifact_dir)

    artifact_path = Path.join(artifact_dir, "#{run_id}-#{task_id}.md")
    expected_comment = "foreman-run:#{run_id}:#{artifact_path}"

    repo_path = make_bare_minimum_git_repo!(test_pid)
    source_revision = current_head_sha!(repo_path)
    on_exit_worktree_cleanup(repo_path, project_id, run_id)

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    phase = put_worktree(phase_spec(script_key, artifact_dir), %{enabled: true})

    expect(BrRunnerMock, :cmd, 1, fn request, _runner_project_config, _opts ->
      assert request == {:update, %{flags: ["--claim", task_id]}}

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "in_progress", %{
               "assignee" => "foreman-runner",
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    task_id,
                    "--status",
                    "open",
                    "--transition-comment",
                    expected_comment
                  ],
                  database_path: database_path
                }}

      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]

      send(test_pid, {:runner_cmd, :fail, request, runner_project_config, opts})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "open", %{
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    seed_project_task_and_run_with_implementation!(
      project_id,
      task_id,
      run_id,
      %{phases: [phase]},
      project_task_provider(database_path),
      %{
        "project_root" => repo_path,
        "source_revision" => source_revision,
        # Not 64-char hex; this MUST fail closed.
        "implementation_key" => "not-a-hex-key",
        "beads_database_path" => database_path
      }
    )

    register_project!(project_id, database_path)

    start_run_executor!(run_id, task_id)

    assert %{status: "failed"} =
             poll_until(
               fn ->
                 case ProjectionStore.task_projection(task_id) do
                   %{status: "failed"} = task -> {:ok, task}
                   other -> :retry
                 end
               end,
               "task failed after provisioning refused (bad implementation_key)"
             )

    refute_received {:adapter_env, _}
    refute_received {:adapter_execute, _, _}
  end

  test "beads-managed phase with missing trd_path fails closed at provisioning" do
    start_schema_cache!()
    test_pid = self()
    project_id = unique_id("project-beads-no-trd")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("wt-beads-no-trd")
    database_path = unique_database_path(unique_id("db"))
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    File.mkdir_p!(artifact_dir)

    artifact_path = Path.join(artifact_dir, "#{run_id}-#{task_id}.md")
    expected_comment = "foreman-run:#{run_id}:#{artifact_path}"

    repo_path = make_bare_minimum_git_repo!(test_pid)
    source_revision = current_head_sha!(repo_path)
    on_exit_worktree_cleanup(repo_path, project_id, run_id)

    implementation_key =
      Base.encode16(:crypto.hash(:sha256, project_id <> run_id), case: :lower)

    LifecycleStore.put(script_key, %{test_pid: test_pid})

    phase = put_worktree(phase_spec(script_key, artifact_dir), %{enabled: true})

    expect(BrRunnerMock, :cmd, 1, fn request, _runner_project_config, _opts ->
      assert request == {:update, %{flags: ["--claim", task_id]}}

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "in_progress", %{
               "assignee" => "foreman-runner",
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request ==
               {:update,
                %{
                  flags: [
                    task_id,
                    "--status",
                    "open",
                    "--transition-comment",
                    expected_comment
                  ],
                  database_path: database_path
                }}

      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]

      send(test_pid, {:runner_cmd, :fail, request, runner_project_config, opts})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "open", %{
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    snapshot =
      Map.put(%{phases: [phase]}, "implementation", %{
        "project_root" => repo_path,
        "source_revision" => source_revision,
        "implementation_key" => implementation_key,
        "beads_database_path" => database_path
      })

    seed_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      snapshot,
      project_task_provider(database_path)
    )

    register_project!(project_id, database_path)

    start_run_executor!(run_id, task_id)

    assert %{status: "failed"} =
             poll_until(
               fn ->
                 case ProjectionStore.task_projection(task_id) do
                   %{status: "failed"} = task -> {:ok, task}
                   other -> :retry
                 end
               end,
               "task failed after provisioning refused (missing trd_path)"
             )

    refute_received {:adapter_env, _}
    refute_received {:adapter_execute, _, _}
  end

  defp put_worktree(phase, worktree_block) do
    Map.put(phase, :worktree, worktree_block)
  end

  defp make_bare_minimum_git_repo!(_test_pid) do
    repo_path = Path.join(System.tmp_dir!(), "run-exec-wt-#{System.unique_integer([:positive])}")
    File.rm_rf!(repo_path)
    File.mkdir_p!(repo_path)
    run_git!(["-C", repo_path, "init", "--initial-branch=main", "--quiet"])
    run_git!(["-C", repo_path, "config", "user.email", "t@x"])
    run_git!(["-C", repo_path, "config", "user.name", "T"])
    File.write!(Path.join(repo_path, "README.md"), "x")
    run_git!(["-C", repo_path, "add", "."])
    run_git!(["-C", repo_path, "commit", "--no-gpg-sign", "-m", "init", "--quiet"])
    repo_path
  end

  defp current_head_sha!(repo_path) do
    run_git!(["-C", repo_path, "rev-parse", "HEAD"]) |> String.trim()
  end

  defp worktree_root_prefix do
    Path.join(System.user_home!(), ".foreman/worktrees") <> "/"
  end

  defp on_exit_worktree_cleanup(repo_path, project_id, run_id) do
    project_root = Path.join([System.user_home!(), ".foreman/worktrees", project_id])
    wt_root = Path.join(project_root, run_id)

    on_exit(fn ->
      File.rm_rf(wt_root)
      File.rm_rf(project_root)
      File.rm_rf(repo_path)
    end)
  end

  defp seed_project_task_and_run_with_implementation!(
         project_id,
         task_id,
         run_id,
         workflow_snapshot,
         task_provider,
         impl_keys
       ) do
    implementation =
      Map.merge(
        %{
          "trd_path" => "docs/TRD/x.md",
          "trd_path_argument" => "docs/TRD/x.md"
        },
        impl_keys
      )

    snapshot = Map.put(workflow_snapshot, "implementation", implementation)
    seed_project_task_and_run!(project_id, task_id, run_id, snapshot, task_provider)
  end

  defp claim_and_complete_expectations!(task_id) do
    expect(BrRunnerMock, :cmd, 1, fn request, _runner_project_config, _opts ->
      assert request == {:update, %{flags: ["--claim", task_id]}}

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "in_progress", %{
               "assignee" => "foreman-runner",
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, _runner_project_config, _opts ->
      assert request == {:close, %{id: task_id}}

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "closed", %{
               "metadata" => %{"provider_id" => "beads", "source" => "br close"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)
  end

  defp poll_run_completion!(run_id) do
    poll_until(
      fn ->
        case ProjectionStore.run(run_id) do
          %{status: status} when status in ["completed", "failed"] -> {:ok, status}
          other -> {:error, other}
        end
      end,
      "run terminal status"
    )
  end

  defp wait_until_cleaned(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_cleaned(path, deadline)
  end

  defp do_wait_until_cleaned(path, deadline) do
    cond do
      not File.dir?(path) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(25)
        do_wait_until_cleaned(path, deadline)
    end
  end

  defp run_git!(args) do
    {out, 0} = System.cmd("git", args, stderr_to_stdout: true)
    out
  end

  defp ensure_started(child_spec, name) do
    if Process.whereis(name) do
      :ok
    else
      start_supervised!(child_spec)
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

  defp start_telemetry_collector(events) do
    collector = spawn_link(fn -> telemetry_collector_loop([]) end)
    ref = :telemetry_test.attach_event_handlers(collector, events)
    {collector, ref}
  end

  defp stop_telemetry_collector(collector) do
    if Process.alive?(collector) do
      send(collector, :stop)
    end
  end

  defp telemetry_collector_loop(events) do
    receive do
      {event, ref, measurements, metadata} ->
        telemetry_collector_loop([
          %{event: event, ref: ref, measurements: measurements, metadata: metadata} | events
        ])

      {:get, caller} ->
        send(caller, {:telemetry_events, Enum.reverse(events)})
        telemetry_collector_loop(events)

      :stop ->
        :ok
    end
  end

  defp telemetry_events(collector) do
    send(collector, {:get, self()})

    receive do
      {:telemetry_events, events} -> events
    after
      1_000 -> flunk("timed out collecting telemetry events")
    end
  end

  defp route_transitions(collector, provider_module) do
    collector
    |> telemetry_events()
    |> Enum.filter(&(&1.event == @route_ok_event and &1.metadata.provider == provider_module))
    |> Enum.map(& &1.metadata.transition)
  end

  defp unique_id(prefix) do
    "#{prefix}-run-executor-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"
  end

  defp unique_database_path(script_key) do
    Path.join(System.tmp_dir!(), "#{script_key}.db")
  end

  defp project_task_provider(database_path) do
    %{
      provider: "beads",
      config: %{"database_path" => database_path}
    }
  end

  defp phase_spec(script_key, artifact_dir) do
    %{
      name: :implement,
      artifact_template: %{path: Path.join([artifact_dir, "{run_id}-{task_id}.md"])},
      context: %{"script_key" => script_key}
    }
  end

  defp issue_payload(task_id, status, overrides) do
    Map.merge(
      %{
        "id" => task_id,
        "title" => "RunExecutor #{task_id}",
        "status" => status,
        "priority" => 2,
        "dependencies" => [],
        "assignee" => nil,
        "description" => "RunExecutor task payload",
        "notes" => nil,
        "design" => nil,
        "labels" => ["workflow", status],
        "metadata" => %{"provider_id" => "beads"}
      },
      overrides
    )
  end

  defp register_project!(project_id, database_path) do
    assert :ok =
             TaskProviderRegistry.register_for_project(project_id, BeadsAdapter, %{
               "database_path" => database_path
             })

    assert TaskProviderRegistry.routing_snapshot()[project_id] == BeadsAdapter

    assert {:active, %{provider_module: BeadsAdapter, config: project_config}} =
             :sys.get_state(TaskProviderRegistry).per_project[project_id]

    assert project_config == %{"database_path" => database_path}
    project_config
  end

  defp start_schema_cache! do
    expect_schema_boot_fetches()
    start_supervised!(JsonSchemaCache)
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
      "metadata" => %{"contractVersion" => "br.capabilities.v1"},
      "properties" => %{
        "commands" => %{"type" => "array"}
      }
    }
  end

  defp assert_database_path(project_config, expected_database_path) do
    assert (Map.get(project_config, :database_path) || Map.get(project_config, "database_path")) ==
             expected_database_path
  end

  defp assert_translated_argv(temp_dir, request, project_config, expected_argv) do
    with_fake_br(
      temp_dir,
      default_fake_br_body(),
      fn ->
        assert {:ok, %{stdout: stdout, stderr: "", exit_code: 0}} =
                 SystemBrRunner.cmd(request, project_config)

        assert String.split(stdout, "\n", trim: true) == expected_argv
      end
    )
  end

  defp default_fake_br_body do
    """
    for arg in "$@"; do
      printf '%s\\n' "$arg"
    done
    """
  end

  defp write_fake_br!(temp_dir, body) do
    script_path = Path.join(temp_dir, "br")
    File.write!(script_path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod!(script_path, 0o755)
  end

  defp with_fake_br(temp_dir, body, fun) do
    original_path = System.get_env("PATH") || ""
    write_fake_br!(temp_dir, body)
    System.put_env("PATH", temp_dir <> ":" <> original_path)

    try do
      fun.()
    after
      System.put_env("PATH", original_path)
    end
  end

  defp stop_schema_cache do
    case Process.whereis(@cache_name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp seed_project!(project_id, task_provider) do
    dispatch_system!("project.register", "project:#{project_id}", %{
      project_id: project_id,
      name: "RunExecutor #{project_id}",
      path: System.tmp_dir!(),
      task_provider: task_provider
    })
  end

  defp seed_project_task_and_run!(
         project_id,
         task_id,
         run_id,
         workflow_snapshot,
         task_provider,
         external_id \\ nil
       ) do
    seed_project!(project_id, task_provider)
    approval_id = unique_id("approval")

    create_payload = %{
      task_id: task_id,
      project_id: project_id,
      task_type: "implement",
      title: "RunExecutor #{task_id}"
    }

    create_payload =
      if is_binary(external_id) and external_id != "" do
        Map.put(create_payload, :external_id, external_id)
      else
        create_payload
      end

    dispatch_system!("task.create", "task:#{task_id}", create_payload)

    dispatch_system!("task.approve", "task:#{task_id}", %{
      task_id: task_id,
      approval_id: approval_id,
      approved_by: "run-executor-test",
      approved_at: "2026-08-06T00:00:00Z",
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

  defp start_run_executor!(run_id, task_id) do
    task = ProjectionStore.task_projection(task_id)

    start_supervised!(%{
      id: {RunExecutor, run_id},
      start: {RunExecutor, :start_link, [run_id, task]},
      restart: :transient,
      shutdown: 5_000,
      type: :worker
    })
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

  defp count_task_events(task_id, event_type) do
    task_id
    |> task_events()
    |> Enum.count(&(&1.event_type == event_type))
  end

  defp task_events(task_id) do
    case EventStore.read_stream_forward("task:#{task_id}", 0, 99_999_999) do
      {:ok, events} -> events
      {:error, :stream_not_found} -> []
    end
  end

  defp receive_message(timeout \\ 1_000) do
    receive do
      message -> message
    after
      timeout -> flunk("expected message within #{timeout}ms")
    end
  end

  # --------------------------------------------------------------------
  # Claim-failure lifecycle (kickoff branch fix)
  # When `maybe_claim_task` returns `{:error, reason}` the executor MUST
  # dispatch both `task.execution_fail` AND `run.fail` before stopping,
  # so the projections transition out of `in_progress` instead of
  # staying stuck forever.
  # --------------------------------------------------------------------

  test "claim failure dispatches task.execution_fail and run.fail so projections reach failed" do
    start_schema_cache!()
    test_pid = self()
    project_id = unique_id("claim-fail-project")
    task_id = unique_id("claim-fail-task")
    run_id = unique_id("claim-fail-run")
    script_key = unique_id("claim-fail-script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("claim-fail-artifacts"))
    File.mkdir_p!(artifact_dir)

    workflow_snapshot = %{phases: [phase_spec(script_key, artifact_dir)]}

    seed_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      project_task_provider(database_path)
    )

    register_project!(project_id, database_path)

    expect(BrRunnerMock, :cmd, 1, fn request, _runner_project_config, _opts ->
      assert request == {:update, %{flags: ["--claim", task_id]}}
      send(test_pid, {:claim_failed, request})
      {:error, %{exit_code: 1, stderr: "br update rejected claim", stdout: ""}}
    end)

    start_run_executor!(run_id, task_id)

    task =
      poll_until(
        fn ->
          case ProjectionStore.task_projection(task_id) do
            %{} = t -> if t.status == "failed", do: {:ok, t}, else: nil
            _ -> nil
          end
        end,
        "task projection to reach failed"
      )

    run =
      poll_until(
        fn ->
          case ProjectionStore.run(run_id) do
            %{} = r -> if r.status == "failed", do: {:ok, r}, else: nil
            _ -> nil
          end
        end,
        "run projection to reach failed"
      )

    assert task.status == "failed"
    assert is_binary(task.failure_reason)
    assert task.failure_reason =~ ":claim_failure"

    assert run.status == "failed"
    assert run.terminal? == true
  end

  test "provider-facing lifecycle calls use the task's external_id, not the Foreman task_id" do
    start_schema_cache!()
    test_pid = self()
    project_id = unique_id("extid-project")
    # Foreman's task_id (e.g. `foreman-mcp-trd`) and the provider's
    # external_id (e.g. Beads issue id `foreman-zuk0`) MUST differ —
    # otherwise the provider CLI rejects the claim with
    # `Error: Issue not found: <foreman-task-id>` because Beads only
    # knows the issue by its short hash. Both identifiers are routed
    # through `unique_id/1` to stay isolated across tests that share
    # the EventStore, while preserving the `task_id != external_id`
    # relationship that exercises the routing fix.
    task_id = "foreman-task-#{unique_id("")}"
    external_id = "foreman-beads-#{unique_id("")}"
    run_id = unique_id("extid-run")
    script_key = unique_id("extid-script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("extid-artifacts"))
    File.mkdir_p!(artifact_dir)

    workflow_snapshot = %{phases: [phase_spec(script_key, artifact_dir)]}
    artifact_path = Path.join(artifact_dir, "#{run_id}-#{task_id}.md")

    seed_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      project_task_provider(database_path),
      external_id
    )

    register_project!(project_id, database_path)

    # Assert the runner receives the EXTERNAL ID, not the Foreman task_id.
    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:update, %{flags: ["--claim", external_id]}}
      assert runner_project_config["database_path"] == database_path
      assert opts == [timeout_ms: 30_000]

      send(test_pid, {:claim_cmd, request, runner_project_config})

      {:ok,
       %{
         exit_code: 0,
         stdout:
           Jason.encode!(
             issue_payload(external_id, "in_progress", %{
               "assignee" => "foreman-runner",
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: ""
       }}
    end)

    # And that close uses the external_id as well.
    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, opts ->
      assert request == {:close, %{id: external_id}}
      assert_database_path(runner_project_config, database_path)
      assert opts == [timeout_ms: 30_000]
      send(test_pid, {:close_cmd, request, runner_project_config})

      {:ok,
       %{
         exit_code: 0,
         stdout:
           Jason.encode!(
             issue_payload(external_id, "closed", %{
               "metadata" => %{"provider_id" => "beads", "source" => "br close"}
             })
           ),
         stderr: ""
       }}
    end)

    # The TestAdapter returns whatever tuple is stored under
    # `:adapter_results` (defaulting to `{:ok, "artifact body", %{}}`).
    # The downstream consumer (`AgentRuntime.Invocation.run_one/4`) only
    # pattern-matches the 3-tuple shape — a 2-tuple makes the case
    # fall through to `CaseClauseError`, which `rescue`s into an error
    # result. That makes the phase fail, which (under `:transient`
    # restart) loops the executor through a second `:kickoff` and a
    # second claim, blowing past our `expect/4` call budget. Match the
    # shape the contract actually consumes.
    LifecycleStore.put(script_key, %{test_pid: test_pid, adapter_results: [{:ok, "ok", %{}}]})

    start_run_executor!(run_id, task_id)

    # Confirm the claim was routed with the external_id.
    assert_receive {:claim_cmd, {:update, %{flags: ["--claim", ^external_id]}}, _}, 1_000

    assert {:adapter_execute, "Run phase implement", context} = receive_message()
    assert context["run_id"] == run_id
    # Foreman-internal context still carries the Foreman task_id.
    assert context["task_id"] == task_id

    assert_receive {:close_cmd, {:close, %{id: ^external_id}}, _}, 1_000

    assert %{status: "closed"} =
             poll_until(
               fn ->
                 case ProjectionStore.task_projection(task_id) do
                   %{status: "closed"} = t -> {:ok, t}
                   other -> :retry
                 end
               end,
               "task projection to reach closed"
             )

    assert File.read!(artifact_path) == "ok"

    # Pinning the boundary: the provider never sees the Foreman task_id.
    refute_receive {:claim_cmd, {:update, %{flags: ["--claim", ^task_id]}}, _}, 100
    refute_receive {:close_cmd, {:close, %{id: ^task_id}}, _}, 100
  end

  test "phase timeout flips the run terminal (run.fail dispatched before task.fail)" do
    start_schema_cache!()
    test_pid = self()
    project_id = unique_id("phase-timeout-project")
    task_id = unique_id("phase-timeout-task")
    run_id = unique_id("phase-timeout-run")
    script_key = unique_id("phase-timeout-script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("phase-timeout-artifacts"))
    File.mkdir_p!(artifact_dir)

    workflow_snapshot = %{phases: [phase_spec(script_key, artifact_dir)]}

    seed_project_task_and_run!(
      project_id,
      task_id,
      run_id,
      workflow_snapshot,
      project_task_provider(database_path)
    )

    register_project!(project_id, database_path)

    LifecycleStore.put(script_key, %{
      test_pid: test_pid,
      adapter_results: [{:error, :timeout}]
    })

    expect(BrRunnerMock, :cmd, 1, fn request, _runner_project_config, _opts ->
      assert request == {:update, %{flags: ["--claim", task_id]}}
      send(test_pid, {:claim_cmd, request})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "in_progress", %{
               "assignee" => "foreman-runner",
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    expect(BrRunnerMock, :cmd, 1, fn request, runner_project_config, _opts ->
      assert_database_path(runner_project_config, database_path)
      assert {:update, %{flags: flags}} = request
      assert Enum.any?(flags, &(&1 == task_id))
      send(test_pid, {:runner_cmd, :fail, request, runner_project_config})

      {:ok,
       %{
         stdout:
           Jason.encode!(
             issue_payload(task_id, "open", %{
               "metadata" => %{"provider_id" => "beads", "source" => "br update"}
             })
           ),
         stderr: "",
         exit_code: 0
       }}
    end)

    start_run_executor!(run_id, task_id)

    # Claim lands first.
    assert_receive {:claim_cmd, {:update, %{flags: ["--claim", ^task_id]}}}, 1_000

    # Adapter receives the phase invocation.
    assert {:adapter_execute, "Run phase implement", _} = receive_message(2_000)

    # Provider reopen/fail callback fires next.
    assert_receive {:runner_cmd, :fail, _, _}, 1_000

    # The invariant: run reaches `failed` and `terminal? == true`. This is
    # the assertion that catches the projection-drift bug where phase.fail
    # was emitted but run.fail was NOT — leaving the run stuck `in_progress`
    # and blocking task.retry.
    run =
      poll_until(
        fn ->
          case ProjectionStore.run(run_id) do
            %{status: "failed", terminal?: true} = r -> {:ok, r}
            _ -> nil
          end
        end,
        "run projection to reach failed + terminal"
      )

    assert run.status == "failed"
    assert run.terminal? == true

    # Task projection also flips failed (via maybe_fail_task after run.fail).
    assert %{status: "failed"} =
             poll_until(
               fn ->
                 case ProjectionStore.task_projection(task_id) do
                   %{status: "failed"} = t -> {:ok, t}
                   _ -> nil
                 end
               end,
               "task projection to reach failed"
             )

    # Pin the events: RunFailed emitted exactly once to the run stream,
    # RunTerminalRecorded by the projection handler, and PhaseFailed on
    # the phase stream.
    run_events =
      case EventStore.read_stream_forward("run:#{run_id}", 0, 99_999_999) do
        {:ok, events} -> events
        {:error, :stream_not_found} -> []
      end

    assert Enum.count(run_events, &(&1.event_type == "RunFailed")) == 1

    phase_events =
      case EventStore.read_stream_forward("phase:#{run_id}:#{run_id}-p001", 0, 99) do
        {:ok, events} -> events
        {:error, :stream_not_found} -> []
      end

    assert Enum.count(phase_events, &(&1.event_type == "PhaseFailed")) == 1
    assert Enum.count(task_events(task_id), &(&1.event_type == "TaskExecutionFailed")) == 1
  end

  describe "init/1 with persisted (string-keyed) projection shape" do
    test "populates phase_specs from string-keyed workflow_snapshot.phases" do
      # The persisted projection is what ProjectionStore.task_projection/1
      # returns after reading the JSON-decoded TaskApproved event: the
      # outer map is atom-keyed but the inner `workflow_snapshot` value
      # carries string keys only. This test pins the contract so a
      # future refactor cannot revert to atom-only pattern matching
      # and silently drop phases.
      #
      # We invoke `RunExecutor.init/1` directly (it is a public `def`)
      # rather than driving a full GenServer — that avoids the
      # `:kickoff` send_after side effect and keeps the test focused
      # on the projection-shape contract.
      projection = %{
        task_id: "task-persisted",
        project_id: "project-persisted",
        workflow_type: "implement-trd",
        workflow_snapshot: %{
          "workflow_name" => "implement-trd",
          "phases" => [
            %{
              "name" => "implement",
              "command" => "/skill:ensemble-full-implement --foreman \"docs/TRD/x.md\"",
              "index" => 1,
              "phase_id" => "phase-1",
              "worktree" => %{
                "enabled" => true,
                "base" => "abc123",
                "branch" => "foreman/{run_id}/{phase}",
                "path" => "implement-trd",
                "cleanup" => "always"
              }
            }
          ],
          "implementation" => %{
            "trd_path_argument" => "\"docs/TRD/x.md\"",
            "source_revision" => "abc123"
          }
        }
      }

      assert {:ok, state} = RunExecutor.init({"run-persisted", projection})
      assert length(state.phase_specs) == 1
      [%{"name" => "implement", "command" => cmd, "worktree" => worktree}] = state.phase_specs
      assert cmd == "/skill:ensemble-full-implement --foreman \"docs/TRD/x.md\""
      assert worktree["base"] == "abc123"
      assert worktree["branch"] == "foreman/{run_id}/{phase}"
    end

    test "falls back to phase_specs == [] when workflow_snapshot is missing or malformed" do
      # Snapshot absent: zero phases is the safe default.
      assert {:ok, state} =
               RunExecutor.init({"run-x1", %{task_id: "t", project_id: "p"}})

      assert state.phase_specs == []

      # Snapshot present but phases key is missing.
      assert {:ok, state} =
               RunExecutor.init({
                 "run-x2",
                 %{task_id: "t", project_id: "p", workflow_snapshot: %{"workflow_name" => "x"}}
               })

      assert state.phase_specs == []

      # Snapshot present but phases is not a list.
      assert {:ok, state} =
               RunExecutor.init({
                 "run-x3",
                 %{task_id: "t", project_id: "p", workflow_snapshot: %{"phases" => "not-a-list"}}
               })

      assert state.phase_specs == []
    end

    test "accepts the atom-keyed in-process projection shape for symmetry" do
      # Same shape with atom keys (used by the in-process projection
      # builder before the JSON round-trip) must also resolve to the
      # same phase count.
      projection = %{
        task_id: "task-atom",
        project_id: "project-atom",
        workflow_type: "implement-trd",
        workflow_snapshot: %{
          workflow_name: "implement-trd",
          phases: [
            %{
              name: "implement",
              command: "/skill:ensemble-full-implement --foreman \"x.md\"",
              index: 1,
              phase_id: "phase-1",
              worktree: %{
                enabled: true,
                base: "abc123",
                branch: "foreman/{run_id}/{phase}",
                path: "implement-trd",
                cleanup: "always"
              }
            }
          ]
        }
      }

      assert {:ok, state} = RunExecutor.init({"run-atom", projection})
      assert length(state.phase_specs) == 1
    end

    test "string-keyed :command phase advances past validate_phase_action and runs the configured command" do
      # Mirror the persisted shape after a JSON round-trip through
      # EventStore: the `TaskApproved` event payload is JSON-encoded,
      # so on replay every key is a string and atom-valued fields like
      # `action: :command` come back as the binary "command". Before
      # the `phase_action/1` and `phase_value/2` fix, two bugs
      # collided:
      #
      #   1. `validate_phase_action` read
      #      `Map.get(phase_spec, :command)` (atom key only) and saw
      #      nil, returning `{:invalid_phase_command, name}` and
      #      terminating the run before `AgentRuntime.execute` was
      #      called.
      #
      #   2. Even if validation passed, `execute_agent` matched
      #      `case ... do :command -> ...`, which fails to match the
      #      string "command", so the configured `/skill:...` would
      #      silently fall through to `request.prompt`.
      #
      # The fix routes both call sites through `phase_action/1`
      # (closed-string remap) and `phase_value/2` (atom/string key
      # fallback) so the persisted shape is accepted end to end.
      script_key = unique_id("strict-script")

      LifecycleStore.put(script_key, %{
        test_pid: self(),
        adapter_results: [{:ok, "ok", %{}}]
      })

      configured_command = "/skill:regression-check --strict-cmd"
      artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
      File.mkdir_p!(artifact_dir)

      projection = %{
        task_id: "task-strict",
        project_id: "project-strict",
        workflow_type: "implement",
        workflow_snapshot: %{
          "workflow_name" => "implement",
          "phases" => [
            %{
              "action" => "command",
              "name" => "strict-phase",
              "command" => configured_command,
              "artifact_template" => %{
                "path" => Path.join([artifact_dir, "{run_id}-{task_id}.md"])
              },
              "context" => %{"script_key" => script_key}
            }
          ]
        }
      }

      {:ok, state} = RunExecutor.init({"run-strict", projection})
      assert length(state.phase_specs) == 1

      # Drive :kickoff synchronously so the assertion below observes
      # the exact message that TestAdapter forwards to the test pid.
      # This bypasses the GenServer mailbox and avoids any
      # `:transient` crash-restart noise; the validation under test
      # runs entirely inside `handle_info/2`.
      {:noreply, _next_state} = RunExecutor.handle_info(:kickoff, state)

      assert_receive {:adapter_execute, ^configured_command, _context}, 1_000
    end
  end

  defp kill_and_restart_dispatcher(_dispatcher) do
    app_sup = Process.whereis(ForemanServer.Application)

    if app_sup do
      :ok = Supervisor.terminate_child(app_sup, ForemanServer.Workflow.Dispatcher)

      {:ok, _new_dispatcher} =
        Supervisor.restart_child(app_sup, ForemanServer.Workflow.Dispatcher)
    end
  end
end
