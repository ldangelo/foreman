defmodule ForemanServer.RunAdmissionProjectRefusalTest do
  # A paused or archived project / exhausted daily cap refuses run admission
  # WITHOUT starting a run, and BEFORE the project's slot stream is touched
  # (TRD-005): a refused run holds no slot and takes no queue position. After
  # the refusal is lifted the same admission succeeds. A project's run ceiling
  # is no longer a refusal: the run waits in the project's queue.
  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregate, CommandRouter, RunAdmission}
  alias ForemanServer.Aggregates.RunSlots
  alias ForemanServer.TestSupport.RunSlotsReset

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
    :ok
  end

  defp ensure_started(child_spec, name) do
    if Process.whereis(name),
      do: :ok,
      else:
        (
          start_supervised!(child_spec)
          :ok
        )
  end

  setup do
    RunSlotsReset.reset!()
    :ok
  end

  defp unique(prefix), do: "#{prefix}-refusal-#{System.unique_integer([:positive])}"

  defp dispatch!(project_id, type, payload) do
    assert {:ok, _} =
             CommandRouter.dispatch(%{
               aggregate_id: "project:#{project_id}",
               command_id: "#{type}:#{project_id}:#{System.unique_integer([:positive])}",
               type: type,
               payload: Map.put(payload, :project_id, project_id)
             })
  end

  defp register!(project_id),
    do: dispatch!(project_id, "project.register", %{path: System.tmp_dir!()})

  # The project's own slot stream, replayed from the event store.
  defp slot_state(project_id) do
    {state, _version} = Aggregate.load(RunSlots, RunSlots.stream_id(project_id))
    state
  end

  defp slot_holders(project_id), do: slot_state(project_id).holders

  defp slot_waiter_ids(project_id),
    do: Enum.map(slot_state(project_id).waiters, & &1.run_id)

  defp payload(run_id) do
    %{
      run_id: run_id,
      task_id: unique("task"),
      workflow_snapshot: %{phases: [%{id: "p", kind: "command"}]},
      phase_specs: [%{phase_id: "p", kind: "command"}],
      approval_id: unique("approval")
    }
  end

  test "paused: admission is deferred with {:project_paused, id}, no slot and no queue position" do
    project_id = unique("project")
    run_id = unique("run")
    register!(project_id)
    dispatch!(project_id, "project.pause", %{})

    assert {:error, {:project_paused, ^project_id}} =
             RunAdmission.start(project_id, payload(run_id))

    refute Map.has_key?(slot_holders(project_id), run_id)
    refute run_id in slot_waiter_ids(project_id)
  end

  test "daily thread cap: the next run is deferred, holds no slot, and is admitted once the cap allows" do
    project_id = unique("project")
    register!(project_id)
    dispatch!(project_id, "project.update", %{daily_thread_cap: 1})

    dispatch!(project_id, "project.reserve_thread", %{
      thread_kind: "jobsite",
      thread_id: unique("js"),
      command_id: unique("c")
    })

    second = unique("run")

    assert {:error, {:daily_thread_cap_exceeded, 1, _day}} =
             RunAdmission.start(project_id, payload(second))

    refute Map.has_key?(slot_holders(project_id), second)
    refute second in slot_waiter_ids(project_id)

    # The cap counts threads per UTC day, so the day rolling over has the same
    # effect as raising it here (the aggregate has no clock seam to roll).
    dispatch!(project_id, "project.update", %{daily_thread_cap: 2})

    assert {:ok, %{"event_type" => "RunStarted"}} =
             RunAdmission.start(project_id, payload(second))

    assert Map.has_key?(slot_holders(project_id), second)
  end

  test "archived: admission is refused before any slot is touched" do
    project_id = unique("project")
    run_id = unique("run")
    register!(project_id)
    dispatch!(project_id, "project.archive", %{})

    assert {:error, :project_archived} =
             RunAdmission.start(project_id, payload(run_id))

    assert slot_holders(project_id) == %{}
    assert slot_waiter_ids(project_id) == []

    assert {:error, :stream_not_found} =
             ForemanServer.EventStore.read_stream_forward(RunSlots.stream_id(project_id), 0, 10)
  end

  test "run limit: the next run waits in the project's queue (not refused) and takes the slot once one is freed" do
    project_id = unique("project")
    register!(project_id)
    dispatch!(project_id, "project.update", %{max_concurrent_runs: 1})

    first = unique("run")
    assert {:ok, %{"event_type" => "RunStarted"}} = RunAdmission.start(project_id, payload(first))
    second = unique("run")

    assert {:ok, :slot_queued} = RunAdmission.start(project_id, payload(second))
    refute Map.has_key?(slot_holders(project_id), second)
    assert slot_waiter_ids(project_id) == [second]

    assert {:ok, _} =
             ForemanServer.CommandGateway.dispatch_system(
               RunSlots.release_command(project_id, first, "test_finished")
             )

    assert Map.has_key?(slot_holders(project_id), second)
    assert slot_waiter_ids(project_id) == []
  end
end
