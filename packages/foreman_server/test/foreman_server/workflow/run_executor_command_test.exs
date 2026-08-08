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
        if Process.alive?(dispatcher), do: :sys.resume(dispatcher)
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
    assert {:ok, _pid} = RunExecutor.start_link(run_id, task)

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
end
