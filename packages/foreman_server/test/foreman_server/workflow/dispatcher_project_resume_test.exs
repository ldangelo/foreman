defmodule ForemanServer.Workflow.DispatcherProjectResumeTest do
  # A paused project refuses admission, which leaves a dispatched task with no
  # run. Nothing else retries it, so `ProjectResumed` (and a settings change,
  # e.g. a raised limit) must re-enter admission for the project's deferred
  # tasks. Other projects' events must not.
  use ExUnit.Case, async: false

  alias ForemanServer.Workflow.Dispatcher

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)
    {:ok, _} = Application.ensure_all_started(:meck)
    :ok
  end

  setup do
    # The app's real Dispatcher stays subscribed to ProjectionStore and handles
    # terminal/resume events emitted by earlier tests. Unfrozen, it would run
    # against the modules mocked below (calling the mocked RunSupervisor.start_run
    # and RunAdmission.start) and put messages in this test's mailbox. See
    # ForemanServer.DispatcherQuiesce.
    :ok = ForemanServer.DispatcherQuiesce.suspend!()

    :meck.new(ForemanServer.ProjectionStore, [:no_link, :passthrough])
    :meck.new(ForemanServer.RunAdmission, [:no_link])
    :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link])

    on_exit(fn ->
      for mod <- [
            ForemanServer.ProjectionStore,
            ForemanServer.RunAdmission,
            ForemanServer.Workflow.RunSupervisor
          ] do
        if :meck.validate(mod), do: :meck.unload(mod)
      end
    end)

    :ok
  end

  defp task(task_id, run_id) do
    %{
      status: "in_progress",
      task_id: task_id,
      run_id: run_id,
      project_id: "proj-resume",
      approval_id: "approval-#{task_id}",
      workflow_snapshot: %{phases: []}
    }
  end

  defp expect_deferred(ids, tasks) do
    :meck.expect(ForemanServer.ProjectionStore, :deferred_task_ids, fn "proj-resume" -> ids end)

    :meck.expect(ForemanServer.ProjectionStore, :task_projection, fn id ->
      Map.get(tasks, id)
    end)
  end

  test "the app's real Dispatcher is frozen while the mocks are installed" do
    expect_deferred(["t1"], %{"t1" => task("t1", "run-1")})
    test_pid = self()

    :meck.expect(ForemanServer.RunAdmission, :start, fn _project, _payload ->
      {:ok, %{event_type: "RunStarted"}}
    end)

    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn run_id, _task, opts ->
      send(test_pid, {:started, run_id, opts})
      {:ok, :child}
    end)

    # An event the real Dispatcher would act on through the mocks: it is the
    # exact leak behind a stray `{:started, "run-1", [resume_from: 0]}`.
    send(
      ForemanServer.Workflow.Dispatcher,
      {:projection_event, %{event_type: "ProjectResumed", data: %{project_id: "proj-resume"}}}
    )

    _ = :sys.get_state(ForemanServer.Workflow.Dispatcher)
    refute_receive {:started, _, _}, 200
  end

  test "ProjectResumed re-enters admission for every deferred task of that project, and starts the run" do
    expect_deferred(["t1", "t2"], %{"t1" => task("t1", "run-1"), "t2" => task("t2", "run-2")})
    test_pid = self()

    :meck.expect(ForemanServer.RunAdmission, :start, fn "proj-resume", payload ->
      send(test_pid, {:admitted, payload.run_id})
      {:ok, %{event_type: "RunStarted"}}
    end)

    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn run_id, _task, opts ->
      send(test_pid, {:started, run_id, opts})
      {:ok, :child}
    end)

    envelope = %{event_type: "ProjectResumed", data: %{project_id: "proj-resume"}}
    assert {:noreply, %{}} = Dispatcher.handle_info({:projection_event, envelope}, %{})

    assert_received {:admitted, "run-1"}
    assert_received {:admitted, "run-2"}
    assert_received {:started, "run-1", []}
    assert_received {:started, "run-2", []}
  end

  test "a settings change (raised limit) retries the deferred tasks too" do
    expect_deferred(["t1"], %{"t1" => task("t1", "run-1")})
    test_pid = self()

    :meck.expect(ForemanServer.RunAdmission, :start, fn _project, payload ->
      send(test_pid, {:admitted, payload.run_id})
      {:error, :run_limit_exceeded}
    end)

    envelope = %{event_type: "ProjectUpdated", data: %{project_id: "proj-resume"}}
    assert {:noreply, _} = Dispatcher.handle_info({:projection_event, envelope}, %{})
    assert_received {:admitted, "run-1"}
  end

  test "a recorded event carrying a typed struct (the real wire shape) is handled" do
    expect_deferred([], %{})

    envelope = %{
      event_type: "ProjectResumed",
      data: %ForemanServer.Events.ProjectResumed{project_id: "proj-resume"}
    }

    assert {:noreply, _} = Dispatcher.handle_info({:projection_event, envelope}, %{})
    assert :meck.called(ForemanServer.ProjectionStore, :deferred_task_ids, ["proj-resume"])
  end

  test "a project with nothing deferred admits nothing" do
    expect_deferred([], %{})
    :meck.expect(ForemanServer.RunAdmission, :start, fn _, _ -> flunk("must not admit") end)

    envelope = %{event_type: "ProjectResumed", data: %{project_id: "proj-resume"}}
    assert {:noreply, _} = Dispatcher.handle_info({:projection_event, envelope}, %{})
  end
end
