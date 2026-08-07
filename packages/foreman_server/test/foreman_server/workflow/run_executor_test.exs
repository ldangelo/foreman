defmodule ForemanServer.Workflow.RunExecutorTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{AgentRuntime, CommandGateway, EventStore, Identity, ProjectionStore}
  alias ForemanServer.AgentRuntime.AdapterCatalog
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.Workflow.RunExecutor

  @route_ok_event [:foreman_server, :task_provider, :registry, :route, :ok]
  @claim_lost_event [:foreman_server, :task_provider, :claim, :lost]
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

  defmodule TestProvider do
    @behaviour ForemanServer.TaskProvider

    @impl true
    def name, do: "run_executor_test_provider"

    @impl true
    def capabilities do
      %{
        provider_id: :run_executor_test_provider,
        contract_version: "br.capabilities.v1",
        supports: [:claim, :close, :reopen]
      }
    end

    @impl true
    def available?, do: true

    @impl true
    def list_ready(project_config, _opts) do
      script_key = script_key(project_config)
      notify(script_key, {:provider_list_ready, project_config})
      LifecycleStore.take(script_key, :list_ready_results, {:ok, []})
    end

    @impl true
    def get(_id, _project_config), do: {:error, %{code: "UNAVAILABLE"}}

    @impl true
    def claim(id, actor, project_config) do
      script_key = script_key(project_config)
      notify(script_key, {:provider_claim, id, actor, project_config})
      LifecycleStore.take(script_key, :claim_results, {:ok, issue(id, "in_progress")})
    end

    @impl true
    def complete(id, completion_token, project_config) do
      script_key = script_key(project_config)
      notify(script_key, {:provider_complete, id, completion_token, project_config})
      LifecycleStore.take(script_key, :complete_results, {:ok, issue(id, "closed")})
    end

    @impl true
    def fail(id, failure_token, project_config) do
      script_key = script_key(project_config)
      notify(script_key, {:provider_fail, id, failure_token, project_config})
      LifecycleStore.take(script_key, :fail_results, {:ok, issue(id, "failed")})
    end

    @impl true
    def reopen(id, transition_comment, project_config) do
      script_key = script_key(project_config)
      notify(script_key, {:provider_reopen_called, id, transition_comment, project_config})
      {:ok, issue(id, "open")}
    end

    @impl true
    def set_priority(_id, _priority, _project_config), do: :ok

    @impl true
    def add_dependency(_id, _depends_on_id, _project_config), do: :ok

    defp script_key(project_config) do
      Map.get(project_config, :script_key) || Map.get(project_config, "script_key")
    end

    defp notify(script_key, message) do
      if pid = LifecycleStore.test_pid(script_key) do
        send(pid, message)
      end
    end

    defp issue(task_id, status) do
      %Issue{
        id: task_id,
        title: "Task #{task_id}",
        status: status,
        priority: "medium",
        dependencies: [],
        assignee: nil,
        description: nil,
        notes: nil,
        design: nil,
        labels: [],
        metadata: %{},
        dependents: []
      }
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

      LifecycleStore.take(script_key, :adapter_results, {:ok, "artifact", %{}})
    end
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)
    previous_task_provider = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      Keyword.merge(previous_task_provider,
        actor: "foreman-runner",
        accepted_contract_versions: ["br.capabilities.v1"]
      )
    )

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
    ensure_started(ForemanServer.TaskProvider.Registry, ForemanServer.TaskProvider.Registry)

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

    ensure_started({LifecycleStore, name: LifecycleStore}, LifecycleStore)

    previous_pi_adapter =
      case AdapterCatalog.lookup(:pi) do
        {:ok, module} -> module
        {:error, :not_found} -> nil
      end

    ensure_test_adapter_registered(previous_pi_adapter)

    on_exit(fn ->
      restore_pi_adapter(previous_pi_adapter)
      Application.put_env(:foreman_server, :task_provider, previous_task_provider)
    end)

    :ok
  end

  setup do
    LifecycleStore.clear()
    :ok
  end

  test "claim emits lost-claim telemetry for NOT_CLAIMABLE provider maps" do
    {collector, handler_id} = attach_collector(@claim_lost_event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    project_id = unique_id("project")
    task_id = unique_id("task")
    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    task_provider = project_task_provider(script_key, database_path)

    LifecycleStore.put(script_key, %{
      test_pid: self(),
      claim_results: [{:error, %{code: "NOT_CLAIMABLE"}}],
      list_ready_results: [{:ok, []}]
    })

    seed_project!(project_id, task_provider)

    assert :ok =
             TaskProviderRegistry.register_for_project(
               project_id,
               TestProvider,
               task_provider.config
             )

    assert {:error, %{code: "NOT_CLAIMABLE"}} =
             RunExecutor.claim(project_id, task_id, "foreman-runner")

    assert_receive {:provider_claim, ^task_id, "foreman-runner", _project_config}, 1_000
    assert_receive {:provider_list_ready, _project_config}, 1_000

    assert [%{event: @claim_lost_event, measurements: %{count: 1}}] =
             poll_until(
               fn ->
                 case telemetry_events(collector) do
                   [] -> {:error, :missing}
                   events -> {:ok, events}
                 end
               end,
               "claim lost telemetry"
             )
  end

  test "successful run claims before adapter execution, closes the task, and never reopens" do
    {collector, handler_id} = attach_collector(@route_ok_event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    task_provider = project_task_provider(script_key, database_path)
    workflow_snapshot = %{phases: [phase_spec(script_key, artifact_dir)]}

    LifecycleStore.put(script_key, %{
      test_pid: self(),
      claim_results: [{:ok, issue(task_id, "in_progress")}],
      complete_results: [{:ok, issue(task_id, "closed")}],
      adapter_results: [{:ok, "artifact body", %{}}]
    })

    seed_project_task_and_run!(project_id, task_id, run_id, workflow_snapshot, task_provider)

    assert :ok =
             TaskProviderRegistry.register_for_project(
               project_id,
               TestProvider,
               task_provider.config
             )

    assert {:ok, _pid} = start_run_executor!(run_id, task_id)

    assert {:provider_claim, ^task_id, "foreman-runner", _project_config} = receive_message()

    assert {:adapter_execute, prompt, context} = receive_message()
    assert prompt == "Run phase implement"
    assert context["script_key"] == script_key
    assert context["phase_id"] == Identity.phase_id(run_id, 1)
    assert context["run_id"] == run_id
    assert context["task_id"] == task_id

    artifact_path = Path.join(artifact_dir, "#{run_id}-#{task_id}.md")

    assert_receive {:provider_complete, ^task_id, completion_token, project_config}, 1_000
    assert completion_token.run_id == run_id
    assert completion_token.artifact_path == artifact_path
    assert fetch_script_key(project_config) == script_key

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
                 case ProjectionStore.run_projection(run_id) do
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
          transitions = route_transitions(collector, TestProvider)

          if Enum.all?([:claim, :close], &(&1 in transitions)) do
            {:ok, transitions}
          else
            {:error, transitions}
          end
        end,
        "route transitions for success"
      )

    assert :claim in transitions
    assert :close in transitions
    refute_receive {:provider_reopen_called, _, _, _}, 100
  end

  test "failed run invokes fail with deterministic transition comment and never reopens" do
    {collector, handler_id} = attach_collector(@route_ok_event)
    on_exit(fn -> :telemetry.detach(handler_id) end)

    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    task_provider = project_task_provider(script_key, database_path)
    workflow_snapshot = %{phases: [phase_spec(script_key, artifact_dir)]}

    LifecycleStore.put(script_key, %{
      test_pid: self(),
      claim_results: [{:ok, issue(task_id, "in_progress")}],
      fail_results: [{:ok, issue(task_id, "failed")}],
      adapter_results: [{:error, :boom}]
    })

    seed_project_task_and_run!(project_id, task_id, run_id, workflow_snapshot, task_provider)

    assert :ok =
             TaskProviderRegistry.register_for_project(
               project_id,
               TestProvider,
               task_provider.config
             )

    assert {:ok, _pid} = start_run_executor!(run_id, task_id)

    assert {:provider_claim, ^task_id, "foreman-runner", _project_config} = receive_message()
    assert {:adapter_execute, _prompt, _context} = receive_message()

    artifact_path = Path.join(artifact_dir, "#{run_id}-#{task_id}.md")

    assert_receive {:provider_fail, ^task_id, failure_token, project_config}, 1_000
    assert failure_token.run_id == run_id
    assert failure_token.artifact_path == artifact_path
    assert failure_token.transition_comment == "foreman-run:#{run_id}:#{artifact_path}"
    assert fetch_script_key(project_config) == script_key

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
          transitions = route_transitions(collector, TestProvider)

          if Enum.all?([:claim, :reopen], &(&1 in transitions)) do
            {:ok, transitions}
          else
            {:error, transitions}
          end
        end,
        "route transitions for failure"
      )

    assert :claim in transitions
    assert :reopen in transitions
    refute_receive {:provider_reopen_called, _, _, _}, 100
  end

  test "second finalize after an already terminal completion does not emit a second task execution event" do
    project_id = unique_id("project")
    task_id = unique_id("task")
    run_id = unique_id("run")
    script_key = unique_id("script")
    database_path = unique_database_path(script_key)
    artifact_dir = Path.join(System.tmp_dir!(), unique_id("artifacts"))
    task_provider = project_task_provider(script_key, database_path)
    workflow_snapshot = %{phases: [phase_spec(script_key, artifact_dir)]}

    LifecycleStore.put(script_key, %{
      test_pid: self(),
      claim_results: [{:ok, issue(task_id, "in_progress")}],
      complete_results: [
        {:ok, issue(task_id, "closed")},
        {:ok, :already_terminal}
      ],
      adapter_results: [{:ok, "artifact body", %{}}]
    })

    seed_project_task_and_run!(project_id, task_id, run_id, workflow_snapshot, task_provider)

    assert :ok =
             TaskProviderRegistry.register_for_project(
               project_id,
               TestProvider,
               task_provider.config
             )

    assert {:ok, _pid} = start_run_executor!(run_id, task_id)

    assert {:provider_claim, ^task_id, "foreman-runner", _project_config} = receive_message()
    assert {:adapter_execute, _prompt, _context} = receive_message()
    assert_receive {:provider_complete, ^task_id, _completion_token, _project_config}, 1_000

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

    assert_receive {:provider_complete, ^task_id, _completion_token, _project_config}, 1_000

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
               "single task execution completed event"
             )

    refute_receive {:provider_reopen_called, _, _, _}, 100
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

  defp attach_collector(event) do
    collector = start_supervised!({Agent, fn -> [] end})
    handler_id = "run-executor-test-#{System.unique_integer([:positive])}"

    :ok = :telemetry.attach(handler_id, event, &__MODULE__.handle_telemetry/4, collector)

    {collector, handler_id}
  end

  def handle_telemetry(event, measurements, metadata, collector) do
    Agent.update(collector, fn events ->
      [%{event: event, measurements: measurements, metadata: metadata} | events]
    end)
  end

  defp telemetry_events(collector) do
    Agent.get(collector, &Enum.reverse/1)
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

  defp project_task_provider(script_key, database_path) do
    %{
      provider: "run_executor_test_provider",
      config: %{"database_path" => database_path, "script_key" => script_key}
    }
  end

  defp phase_spec(script_key, artifact_dir) do
    %{
      name: :implement,
      artifact_template: %{path: Path.join([artifact_dir, "{run_id}-{task_id}.md"])},
      context: %{"script_key" => script_key}
    }
  end

  defp issue(task_id, status) do
    %Issue{
      id: task_id,
      title: "Task #{task_id}",
      status: status,
      priority: "medium",
      dependencies: [],
      assignee: nil,
      description: nil,
      notes: nil,
      design: nil,
      labels: [],
      metadata: %{},
      dependents: []
    }
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

  defp fetch_script_key(project_config) do
    Map.get(project_config, :script_key) || Map.get(project_config, "script_key")
  end

  defp receive_message(timeout \\ 1_000) do
    receive do
      message -> message
    after
      timeout -> flunk("expected message within #{timeout}ms")
    end
  end
end
