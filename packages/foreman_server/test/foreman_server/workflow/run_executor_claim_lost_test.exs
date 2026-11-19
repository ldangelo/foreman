defmodule ForemanServer.Workflow.RunExecutorClaimLostTest do
  @moduledoc """
  The provider-generic lost-claim path of `RunExecutor.claim/4`, through a `sqlite`-style
  provider (`FakeTaskProvider`) rather than Kata: a refusal (`NOT_CLAIMABLE`, `CLAIMED_BY_OTHER`)
  refreshes the ready set once, claims once more if the task is still ready, and is lost when
  the retry is refused again or the task is gone. Any other error is returned untouched.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TestSupport.{FakeTaskProvider, KeyStoreReset, TestApplication}
  alias ForemanServer.Workflow.RunExecutor

  @lost_event [:foreman_server, :task_provider, :claim, :lost]
  @actor "foreman-runner"
  @refusal_codes ["NOT_CLAIMABLE", "CLAIMED_BY_OTHER"]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)
    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)
    ensure_started(Registry, Registry)
    :ok
  end

  setup do
    previous_provider = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: @actor,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    TestApplication.reset_application_child!(Registry)

    # A running dispatcher would poll the registered provider's ready set, consuming the script.
    dispatcher = Process.whereis(ForemanServer.Workflow.Dispatcher)

    if dispatcher do
      :sys.suspend(dispatcher)
      on_exit(fn -> ForemanServer.TestSupport.DispatcherRestart.restart!() end)
    end

    KeyStoreReset.reset!()
    start_supervised!(FakeTaskProvider)

    lost_ref = :telemetry_test.attach_event_handlers(self(), [@lost_event])

    on_exit(fn ->
      :telemetry.detach(lost_ref)
      Application.put_env(:foreman_server, :task_provider, previous_provider)
      KeyStoreReset.reset!()
    end)

    {:ok, lost_ref: lost_ref}
  end

  for code <- @refusal_codes do
    describe "a claim refused with #{code}" do
      test "that is ready again after the refresh is claimed once more, and is not lost",
           %{lost_ref: lost_ref} do
        %{project_id: project_id, db: db, task_id: task_id, run_id: run_id} = world()
        script_claims(db, [{:error, refusal(unquote(code))}])
        script_ready(db, [{:ok, [ready_issue(db, task_id)]}])

        assert {:ok, %{id: ^task_id, status: "in_progress", assignee: @actor}} =
                 RunExecutor.claim(project_id, task_id, @actor, run_id)

        assert FakeTaskProvider.calls(db) == [{:claim, task_id}, {:claim, task_id}]
        assert FakeTaskProvider.refreshes(db) == 1
        refute_received {@lost_event, ^lost_ref, _measurements, _metadata}
      end

      test "again after the refresh is lost, and is never attempted a third time",
           %{lost_ref: lost_ref} do
        %{project_id: project_id, db: db, task_id: task_id, run_id: run_id} = world()
        refusal = refusal(unquote(code))
        script_claims(db, [{:error, refusal}, {:error, refusal}])
        script_ready(db, [{:ok, [ready_issue(db, task_id)]}])

        assert {:error, ^refusal} = RunExecutor.claim(project_id, task_id, @actor, run_id)

        # A third claim would apply for real: the issue would be in_progress.
        assert FakeTaskProvider.calls(db) == [{:claim, task_id}, {:claim, task_id}]
        assert FakeTaskProvider.status(db, task_id) == "open"
        assert FakeTaskProvider.refreshes(db) == 1
        assert_received {@lost_event, ^lost_ref, %{count: 1}, %{}}
        refute_received {@lost_event, ^lost_ref, _measurements, _metadata}
      end

      test "for a task that is no longer ready is lost after one refresh, with no retry",
           %{lost_ref: lost_ref} do
        %{project_id: project_id, db: db, task_id: task_id, run_id: run_id} = world()
        refusal = refusal(unquote(code))
        script_claims(db, [{:error, refusal}])
        script_ready(db, [{:ok, [ready_issue(db, "some-other-task")]}])

        assert {:error, ^refusal} = RunExecutor.claim(project_id, task_id, @actor, run_id)

        assert FakeTaskProvider.calls(db) == [{:claim, task_id}]
        assert FakeTaskProvider.refreshes(db) == 1
        assert_received {@lost_event, ^lost_ref, %{count: 1}, %{}}
        refute_received {@lost_event, ^lost_ref, _measurements, _metadata}
      end
    end
  end

  describe "a claim that fails for another reason" do
    test "is returned as it came: no refresh, no retry, no loss", %{lost_ref: lost_ref} do
      %{project_id: project_id, db: db, task_id: task_id, run_id: run_id} = world()
      error = FakeTaskProvider.error("br down", true)
      script_claims(db, [{:error, error}])
      # Were the refresh to run, the task would look ready and be claimed again for real.
      script_ready(db, [{:ok, [ready_issue(db, task_id)]}])

      assert {:error, ^error} = RunExecutor.claim(project_id, task_id, @actor, run_id)

      assert FakeTaskProvider.calls(db) == [{:claim, task_id}]
      assert FakeTaskProvider.refreshes(db) == 0
      refute_received {@lost_event, ^lost_ref, _measurements, _metadata}
    end
  end

  defp refusal(code),
    do: %ProviderError{
      code: code,
      message: "task is held by another actor",
      hint: "",
      retryable?: false,
      context: %{}
    }

  defp script_claims(db, results), do: FakeTaskProvider.script(db, :claim, results)
  defp script_ready(db, results), do: FakeTaskProvider.script(db, :list_ready, results)

  defp ready_issue(db, id) do
    FakeTaskProvider.put_issue(db, id, "open")
    {:ok, issue} = FakeTaskProvider.get(id, %{"database_path" => db})
    issue
  end

  # A project registered with the fake provider through the real `project.register` command; the
  # claim needs no run, so none is started.
  defp world do
    n = System.unique_integer([:positive])
    project_id = "project-claim-lost-#{n}"
    db = "/abs/claim-lost/#{project_id}.db"

    command_id = "project.register:project:#{project_id}:#{n}"

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: command_id,
               aggregate_id: "project:#{project_id}",
               type: "project.register",
               payload: %{
                 project_id: project_id,
                 name: project_id,
                 path: System.tmp_dir!(),
                 task_provider: %{
                   provider: FakeTaskProvider.provider_ref(),
                   config: %{"database_path" => db}
                 }
               }
             })

    # The projector that turns `task_provider` config into registry routing is not part of this
    # test's tree: register the same module and config it would.
    assert :ok =
             Registry.register_for_project(project_id, FakeTaskProvider, %{"database_path" => db})

    await_projection(project_id)

    %{
      project_id: project_id,
      db: db,
      task_id: "task-claim-lost-#{n}",
      run_id: "run-claim-lost-#{n}"
    }
  end

  defp await_projection(project_id, attempts \\ 200) do
    cond do
      match?(%{}, ProjectionStore.project_projection(project_id)) ->
        :ok

      attempts == 0 ->
        flunk("project #{project_id} never reached the projection")

      true ->
        Process.sleep(25)
        await_projection(project_id, attempts - 1)
    end
  end

  defp ensure_started(child_spec, name) do
    if Process.whereis(name) == nil, do: start_supervised!(child_spec)
    :ok
  end
end
