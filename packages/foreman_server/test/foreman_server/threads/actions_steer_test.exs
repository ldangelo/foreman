defmodule ForemanServer.Threads.ActionsSteerTest do
  # `Threads.Actions.steer/3` on both doors: the workflow door queues
  # `run.steer` on the run aggregate; the jobsite door is retired
  # (`{:error, :jobsite_retired}`).
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.CommandRouter
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads.Actions


  setup do
    :ok = ProjectionStore.subscribe(replay_existing: false)
    slot_init = "thread-steer-slot-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run_slots.acquire",
        command_id: "thread-steer-test:#{slot_init}",
        aggregate_id: "run_slots:global",
        payload: %{run_id: slot_init, capacity: 100}
      })

    on_exit(fn ->
      CommandGateway.dispatch_system(%{
        type: "run_slots.release",
        command_id: "thread-steer-test:release:#{slot_init}",
        aggregate_id: "run_slots:global",
        payload: %{run_id: slot_init}
      })
    end)

    :ok
  end

  describe "workflow door" do
    test "queues the message on the run and echoes the supplied message_id" do
      run_id = start_run!()

      assert {:ok, %{message_id: "m-1", mode: :pause_resume}} =
               Actions.steer("run:" <> run_id, "use the cache", message_id: "m-1")

      queued = await_event("RunSteerQueued", :run_id, run_id)
      assert field(queued, :message_id) == "m-1"
      assert field(queued, :text) == "use the cache"
      assert field(queued, :resume) == true

      assert [%{message_id: "m-1", text: "use the cache"}] =
               ProjectionStore.pending_steering(run_id)
    end

    test "resume: false is carried on the event; generated ids are unique" do
      run_id = start_run!()

      assert {:ok, %{message_id: a}} = Actions.steer("run:" <> run_id, "one", resume: false)
      assert {:ok, %{message_id: b}} = Actions.steer("run:" <> run_id, "two")
      assert a != b

      assert field(await_event("RunSteerQueued", :run_id, run_id), :resume) == false
    end

    test "re-sending the same message_id queues it once" do
      run_id = start_run!()
      opts = [message_id: "dup"]

      assert {:ok, _} = Actions.steer("run:" <> run_id, "same", opts)
      assert {:ok, _} = Actions.steer("run:" <> run_id, "same", opts)
      await_event("RunSteerQueued", :run_id, run_id)

      assert [%{message_id: "dup"}] = ProjectionStore.pending_steering(run_id)
    end

    test "a terminal run is {:not_steerable, status} on the same typed error" do
      run_id = start_run!()
      assert {:ok, :stopping} = Actions.stop("run:" <> run_id)
      await_event("RunCancelled", :run_id, run_id)

      assert {:error, {:not_steerable, "cancelled"}} = Actions.steer("run:" <> run_id, "late")
      assert ProjectionStore.pending_steering(run_id) == []
    end

    test "blank, non-string and oversize text are rejected before dispatch" do
      run_id = start_run!()

      assert {:error, {:invalid_text, :blank}} = Actions.steer("run:" <> run_id, "  ")
      assert {:error, {:invalid_text, :blank}} = Actions.steer("run:" <> run_id, nil)

      assert {:error, {:invalid_text, :too_long}} =
               Actions.steer("run:" <> run_id, String.duplicate("x", 8001))

      assert ProjectionStore.pending_steering(run_id) == []
    end
  end

  test "unknown thread" do
    assert {:error, :thread_not_found} = Actions.steer("run:nope-steer", "hi")
    assert {:error, :thread_not_found} = Actions.steer("jobsite:nope-steer", "hi")
  end

  # -- helpers ---------------------------------------------------------------

  defp unique(prefix), do: "#{prefix}-thread-steer-#{System.unique_integer([:positive])}"

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

  defp field(data, key) do
    case Map.fetch(data, key) do
      {:ok, value} -> value
      :error -> data[to_string(key)]
    end
  end

  defp await_event(type, key, id) do
    receive do
      {:projection_event, %{event_type: ^type, data: data}} ->
        if field(data, key) == id, do: data, else: await_event(type, key, id)

      {:projection_event, _other} ->
        await_event(type, key, id)
    after
      30_000 -> flunk("timed out waiting for #{type} on #{id}")
    end
  end
end
