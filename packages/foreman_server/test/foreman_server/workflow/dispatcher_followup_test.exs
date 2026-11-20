defmodule ForemanServer.Workflow.DispatcherFollowUpTest do
  @moduledoc """
  The Dispatcher admits a recorded follow-up run request (`RunFollowUpRequested`) through
  `RunAdmission.start/2` as a task-less run, queues it behind full slots like any run, finds it
  again after a slot promotion, and never restarts a run that is already terminal.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.TestSupport.MeckScope
  alias ForemanServer.Workflow.{Dispatcher, FollowUp}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)
    {:ok, _} = Application.ensure_all_started(:meck)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    MeckScope.new_once!(ForemanServer.ProjectionStore)
  end

  setup do
    :ok = ForemanServer.DispatcherQuiesce.suspend!()

    :meck.new(ForemanServer.RunAdmission, [:no_link])
    :meck.new(ForemanServer.Workflow.RunSupervisor, [:no_link])

    :meck.expect(ForemanServer.ProjectionStore, :tasks_by_run_id, fn _ -> [] end)
    :meck.expect(ForemanServer.ProjectionStore, :run, fn _ -> nil end)
    :meck.expect(ForemanServer.RunAdmission, :start, fn _, _ -> {:ok, %{}} end)

    :meck.expect(ForemanServer.Workflow.RunSupervisor, :start_run, fn _, _, _ ->
      {:ok, :started}
    end)

    on_exit(fn ->
      for mod <- [ForemanServer.RunAdmission, ForemanServer.Workflow.RunSupervisor] do
        if :meck.validate(mod), do: :meck.unload(mod)
      end
    end)

    MeckScope.restore_on_exit!(ForemanServer.ProjectionStore)
    :ok
  end

  defp request(run_id, overrides \\ %{}) do
    Map.merge(
      %{
        run_id: run_id,
        project_id: "proj-fu",
        kind: "pr_fix",
        attach_branch: "feature/x",
        push: true,
        prompt: "fix the ci",
        provider: "claude",
        model: "haiku",
        approval_mode: "auto_edit",
        resume_session_provider: nil,
        resume_session_id: nil
      },
      overrides
    )
  end

  defp stub_request(run_id, request) do
    :meck.expect(ForemanServer.ProjectionStore, :followup_request, fn ^run_id -> request end)
  end

  defp requested(run_id) do
    %{event_type: "RunFollowUpRequested", data: %{run_id: run_id}}
  end

  test "admits the request as a task-less run and starts the executor with the follow-up task map" do
    run_id = "run-fu-#{unique_id()}"
    stub_request(run_id, request(run_id))

    :meck.expect(ForemanServer.RunAdmission, :start, fn "proj-fu", payload ->
      assert payload.run_id == run_id
      assert payload.task_id == nil
      assert [%{"name" => "fix", "provider" => "claude"} = phase] = payload.phase_specs
      assert phase["models"] == %{"default" => "haiku"}
      assert phase["approval_mode"] == "auto_edit"
      {:ok, %{}}
    end)

    assert {:noreply, _} = Dispatcher.handle_info({:projection_event, requested(run_id)}, %{})

    assert [{_pid, {_, :start_run, [^run_id, task, opts]}, _}] =
             :meck.history(ForemanServer.Workflow.RunSupervisor)

    assert task.provider_tracked == false
    assert task.followup.attach_branch == "feature/x"
    assert task.followup.prompt == "fix the ci"
    refute Map.has_key?(task, :task_id)
    assert opts == []
  end

  test "a request that names a session starts the run with resume_session" do
    run_id = "run-fu-#{unique_id()}"

    stub_request(
      run_id,
      request(run_id, %{resume_session_provider: "claude", resume_session_id: "s-1"})
    )

    Dispatcher.handle_info({:projection_event, requested(run_id)}, %{})

    assert [{_, {_, :start_run, [^run_id, _task, opts]}, _}] =
             :meck.history(ForemanServer.Workflow.RunSupervisor)

    assert opts == [resume_session: {"claude", "s-1"}]
  end

  test "a request refused or queued by admission starts nothing" do
    run_id = "run-fu-#{unique_id()}"
    stub_request(run_id, request(run_id))

    for result <- [{:ok, :slot_queued}, {:ok, :queued}, {:error, :project_paused}] do
      :meck.expect(ForemanServer.RunAdmission, :start, fn _, _ -> result end)
      Dispatcher.handle_info({:projection_event, requested(run_id)}, %{})
    end

    refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
  end

  test "a terminal run is never started again (boot replays every request)" do
    run_id = "run-fu-#{unique_id()}"
    stub_request(run_id, request(run_id))
    :meck.expect(ForemanServer.ProjectionStore, :run, fn ^run_id -> %{terminal?: true} end)

    Dispatcher.handle_info({:projection_event, requested(run_id)}, %{})

    refute :meck.called(ForemanServer.RunAdmission, :start, :_)
    refute :meck.called(ForemanServer.Workflow.RunSupervisor, :start_run, :_)
  end

  test "a request the projection does not know is skipped" do
    run_id = "run-fu-#{unique_id()}"
    stub_request(run_id, nil)

    assert {:noreply, _} = Dispatcher.handle_info({:projection_event, requested(run_id)}, %{})
    refute :meck.called(ForemanServer.RunAdmission, :start, :_)
  end

  test "a slot promotion finds a task-less run by its follow-up request" do
    run_id = "run-fu-#{unique_id()}"

    stub_request(
      run_id,
      request(run_id, %{resume_session_provider: "claude", resume_session_id: "s-9"})
    )

    envelope = %{event_type: "RunSlotTransferred", data: %{acquired_run_id: run_id}}
    assert {:noreply, _} = Dispatcher.handle_info({:projection_event, envelope}, %{})

    assert [{_, {_, :start_run, [^run_id, _task, [resume_session: {"claude", "s-9"}]]}, _}] =
             :meck.history(ForemanServer.Workflow.RunSupervisor)
  end

  test "FollowUp builds a one-phase snapshot and no task id" do
    payload = FollowUp.run_payload(request("run-x", %{sandbox: "docker"}))
    assert payload.task_id == nil
    assert payload.workflow_snapshot["sandbox"] == "docker"
    assert payload.workflow_snapshot["worktree"]["enabled"] == true
  end

  defp unique_id, do: System.unique_integer([:positive])

  defp ensure_started(child_spec, name) do
    if Process.whereis(name) == nil, do: start_supervised!(child_spec)
    :ok
  end
end
