defmodule ForemanServer.RunAdmissionProjectRefusalTest do
  # A paused project / exhausted daily cap refuses run admission WITHOUT starting
  # a run. The global run slot the attempt acquired must be handed back, or one
  # paused project would starve every other project. After the refusal is lifted
  # the same admission succeeds.
  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregate, CommandRouter, RunAdmission}
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
    init_run_id = "refusal-init-#{System.unique_integer([:positive])}"

    {:ok, _} =
      ForemanServer.CommandGateway.dispatch_system(%{
        type: "run_slots.acquire",
        command_id: "test:refusal-init:#{init_run_id}",
        aggregate_id: "run_slots:global",
        payload: %{run_id: init_run_id, capacity: 100}
      })

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

  defp slot_holders do
    {:ok, pid} = start_or_lookup_slots()
    Aggregate.Actor.get_state(pid).holders
  end

  defp start_or_lookup_slots do
    case Registry.lookup(ForemanServer.AggregateRegistry, "run_slots:global") do
      [{pid, _}] -> {:ok, pid}
      [] -> flunk("run_slots:global aggregate not started")
    end
  end

  defp payload(run_id) do
    %{
      run_id: run_id,
      task_id: unique("task"),
      workflow_snapshot: %{phases: [%{id: "p", kind: "command"}]},
      phase_specs: [%{phase_id: "p", kind: "command"}],
      approval_id: unique("approval")
    }
  end

  test "paused: admission is refused with {:project_paused, id} and the slot is not taken" do
    project_id = unique("project")
    run_id = unique("run")
    register!(project_id)
    dispatch!(project_id, "project.pause", %{})

    assert {:error, {:project_paused, ^project_id}} =
             RunAdmission.start(project_id, payload(run_id))

    refute Map.has_key?(slot_holders(), run_id)
  end

  test "daily thread cap: the next run is refused and the slot is not taken" do
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

    refute Map.has_key?(slot_holders(), second)
  end
end
