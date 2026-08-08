defmodule ForemanServer.Workflow.RunExecutorTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.{AgentRuntime, CommandGateway, EventStore, Identity, ProjectionStore}
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
    def execute(%{prompt: prompt, context: context}, _opts) do
      script_key = Map.fetch!(context, "script_key")

      if pid = LifecycleStore.test_pid(script_key) do
        send(pid, {:adapter_execute, prompt, context})
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
    start_supervised!(TaskProviderRegistry)
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

    assert {:ok, _pid} = start_run_executor!(run_id, task_id)

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

    assert {:ok, _pid} = start_run_executor!(run_id, task_id)

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

    assert {:ok, _pid} = start_run_executor!(run_id, task_id)

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

  defp seed_project_task_and_run!(project_id, task_id, run_id, workflow_snapshot, task_provider) do
    seed_project!(project_id, task_provider)

    dispatch_system!("task.create", "task:#{task_id}", %{
      task_id: task_id,
      project_id: project_id,
      task_type: "implement",
      title: "RunExecutor #{task_id}"
    })

    dispatch_system!("task.approve", "task:#{task_id}", %{
      task_id: task_id,
      approval_id: unique_id("approval"),
      approved_by: "run-executor-test",
      approved_at: "2026-08-06T00:00:00Z",
      run_id: run_id,
      workflow_snapshot: workflow_snapshot
    })

    dispatch_system!("task.dispatch", "task:#{task_id}", %{task_id: task_id})

    dispatch_system!("run.start", "run:#{run_id}", %{
      run_id: run_id,
      task_id: task_id,
      project_id: project_id,
      workflow_snapshot: workflow_snapshot
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
    RunExecutor.start_link(run_id, task)
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
end
