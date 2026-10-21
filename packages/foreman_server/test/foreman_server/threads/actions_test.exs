defmodule ForemanServer.Threads.ActionsTest do
  # `Threads.Actions.stop/3` on both doors, driven by real events: a run is
  # started with `CommandRouter.dispatch_run_start/2` (no global slot gate, which other
  # tests can exhaust) and a jobsite through its aggregate, so the thread's status
  # comes from the live projection.
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.CommandRouter
  alias ForemanServer.EventStore
  alias ForemanServer.Jobsite.Control
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads
  alias ForemanServer.Threads.Actions

  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    :ok
  end

  describe "workflow door" do
    test "stops a live run: RunCancelled lands and the projection reads cancelled" do
      run_id = start_run!()
      assert {:ok, %{status: status}} = Threads.get("run:" <> run_id)
      assert status in ~w(awaiting_worker in_progress)

      assert {:ok, :stopping} = Actions.stop("run:" <> run_id, "enough")

      cancelled = await_event("RunCancelled", :run_id, run_id)
      assert field(cancelled, :reason) == "enough"
      assert ProjectionStore.run(run_id).status == "cancelled"
      assert {:ok, %{status: "cancelled"}} = Threads.get("run:" <> run_id)
    end

    test "default reason is operator_stop" do
      run_id = start_run!()
      assert {:ok, :stopping} = Actions.stop("run:" <> run_id)
      assert field(await_event("RunCancelled", :run_id, run_id), :reason) == "operator_stop"
    end

    test "a terminal run is rejected with its status and nothing is appended" do
      run_id = start_run!()
      assert {:ok, :stopping} = Actions.stop("run:" <> run_id)
      await_event("RunCancelled", :run_id, run_id)

      before = stream_length("run:" <> run_id)

      assert {:error, {:not_stoppable, "cancelled"}} = Actions.stop("run:" <> run_id)
      assert stream_length("run:" <> run_id) == before
    end
  end

  describe "jobsite door" do
    test "a paused jobsite has no executor: the jobsite.cancel command ends it" do
      id = start_jobsite!()
      :ok = pause_jobsite!(id)

      assert {:ok, %{status: "paused"}} = Threads.get("jobsite:" <> id)
      assert {:ok, :stopping} = Actions.stop("jobsite:" <> id, "enough")

      assert field(await_event("JobsiteCancelled", :jobsite_id, id), :reason) == "enough"
      assert {:ok, %{status: "cancelled"}} = Threads.get("jobsite:" <> id)
    end

    test "a terminal jobsite is rejected with its status and nothing is appended" do
      id = start_jobsite!()
      :ok = pause_jobsite!(id)
      assert {:ok, :stopping} = Actions.stop("jobsite:" <> id)
      await_event("JobsiteCancelled", :jobsite_id, id)

      before = stream_length("jobsite:" <> id)

      assert {:error, {:not_stoppable, "cancelled"}} = Actions.stop("jobsite:" <> id)
      assert stream_length("jobsite:" <> id) == before
    end

    test "a live executor is asked to cancel through the existing control intent" do
      id = start_jobsite!()
      {:ok, _} = Registry.register(ForemanServer.Jobsite.Registry, id, nil)
      on_exit(fn -> Control.clear(id) end)

      assert {:ok, :stopping} = Actions.stop("jobsite:" <> id, "enough")
      assert Control.intent(id) == {:cancel, "enough"}

      # The executor, not Actions, appends JobsiteCancelled: nothing yet.
      assert stream_length("jobsite:" <> id) == 1
    end

    test "a starting jobsite whose executor is gone is not silently 'stopped'" do
      id = start_jobsite!()

      assert {:ok, %{status: "starting"}} = Threads.get("jobsite:" <> id)
      assert {:error, {:no_executor, "starting"}} = Actions.stop("jobsite:" <> id)
      assert Control.intent(id) == :none
      assert stream_length("jobsite:" <> id) == 1
    end
  end

  test "unknown thread" do
    assert {:error, :thread_not_found} = Actions.stop("run:does-not-exist")
    assert {:error, :thread_not_found} = Actions.stop("jobsite:does-not-exist")
  end

  # -- helpers ---------------------------------------------------------------

  defp unique(prefix), do: "#{prefix}-thread-stop-#{System.unique_integer([:positive])}"

  defp start_run! do
    project_id = unique("project")
    run_id = unique("run")

    assert {:ok, _} =
             CommandRouter.dispatch(%{
               aggregate_id: "project:#{project_id}",
               command_id: "register:#{project_id}",
               type: "project.register",
               payload: %{project_id: project_id, name: project_id, path: System.tmp_dir!()}
             })

    assert {:ok, _} =
             CommandRouter.dispatch_run_start(project_id, %{
               run_id: run_id,
               task_id: unique("task"),
               workflow_snapshot: %{phases: [%{id: "phase-1", kind: "command"}]},
               phase_specs: [%{phase_id: "phase-1", kind: "command"}],
               approval_id: unique("approval")
             })

    await_event("RunStarted", :run_id, run_id)
    run_id
  end

  defp start_jobsite! do
    id = unique("js")

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               type: "jobsite.start",
               command_id: "thread-stop-test:#{id}:start",
               aggregate_id: "jobsite:#{id}",
               payload: %{jobsite_id: id, repo_path: "/tmp/none", strategy: "head"}
             })

    await_event("JobsiteStarted", :jobsite_id, id)
    id
  end

  defp pause_jobsite!(id) do
    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               type: "jobsite.pause",
               command_id: "thread-stop-test:#{id}:pause",
               aggregate_id: "jobsite:#{id}",
               payload: %{jobsite_id: id, reason: "manual"}
             })

    await_event("JobsitePaused", :jobsite_id, id)
    :ok
  end

  defp field(data, key), do: data[key] || data[to_string(key)]

  defp await_event(type, key, id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if field(data, key) == id, do: data, else: await_event(type, key, id)

      {:projection_event, _other} ->
        await_event(type, key, id)
    after
      15_000 -> flunk("timed out waiting for #{type} on #{id}")
    end
  end

  defp stream_length(stream) do
    case EventStore.read_stream_forward(stream, 0, 99_999) do
      {:ok, events} -> length(events)
      {:error, :stream_not_found} -> 0
    end
  end
end
