defmodule ForemanServer.PhaseAggregateTest do
  use ExUnit.Case, async: false

  alias ForemanServer.{AggregateRouter, Aggregate.Actor, CommandRouter, EventStore}
  alias ForemanServer.Aggregates.Phase

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-phase-aggregate-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    assert :ok = Application.start(:foreman_server)
    :ok
  end

  test "AC-005-1: phase.start appends PhaseStarted and actor state becomes active" do
    stream_id = "phase:run-start:build"
    {:ok, pid} = Actor.start_link(Phase, stream_id)

    assert {:ok, %{event: event}} =
             Actor.command(
               pid,
               "phase.start",
               %{run_id: "run-start", phase_id: "build"},
               "phase-start:run-start:build"
             )

    assert event.event_type == "PhaseStarted"
    assert event.stream_version == 1

    assert %Phase.State{
             exists?: true,
             run_id: "run-start",
             phase_id: "build",
             status: "in_progress",
             terminal?: false,
             attempt: 0
           } = Actor.current_state(pid)
  end

  test "AC-005-2: phase.complete appends PhaseCompleted and actor state becomes terminal" do
    stream_id = "phase:run-complete:test"
    {:ok, pid} = Actor.start_link(Phase, stream_id)

    assert {:ok, %{event: %{event_type: "PhaseStarted"}}} =
             Actor.command(
               pid,
               "phase.start",
               %{run_id: "run-complete", phase_id: "test"},
               "phase-start:run-complete:test"
             )

    assert {:ok, %{event: event}} =
             Actor.command(
               pid,
               "phase.complete",
               %{run_id: "run-complete", phase_id: "test"},
               "phase-complete:run-complete:test"
             )

    assert event.event_type == "PhaseCompleted"
    assert event.stream_version == 2

    assert %Phase.State{
             exists?: true,
             run_id: "run-complete",
             phase_id: "test",
             status: "completed",
             terminal?: true,
             attempt: 0
           } = Actor.current_state(pid)

    assert ["PhaseStarted", "PhaseCompleted"] ==
             EventStore.stream(stream_id) |> Enum.map(& &1.event_type)
  end

  test "AC-005-3: stale routed CompletePhase conflicts and fresh routing sees terminal state" do
    assert {:ok, start_spec} =
             AggregateRouter.route("phase.start", %{run_id: "run-race", phase_id: "qa"})

    assert {:ok, %{stream_version: 1}} = EventStore.append(start_spec)

    assert {:ok, spec1} =
             AggregateRouter.route("phase.complete", %{run_id: "run-race", phase_id: "qa"})

    assert {:ok, spec2} =
             AggregateRouter.route("phase.complete", %{run_id: "run-race", phase_id: "qa"})

    assert spec1.expected_stream_version == 1
    assert spec2.expected_stream_version == 1

    assert {:ok, %{stream_version: 2}} = EventStore.append(spec1)

    assert {:error, {:conflict, [expected: 1, actual: 2]}} = EventStore.append(spec2)

    assert {:error, :phase_terminal} =
             AggregateRouter.route("phase.complete", %{run_id: "run-race", phase_id: "qa"})
  end

  test "AC-005-3: stale actor retries CompletePhase after conflict and reloads terminal state" do
    stream_id = "phase:run-actor-race:package"

    assert {:ok, start_spec} =
             AggregateRouter.route("phase.start", %{run_id: "run-actor-race", phase_id: "package"})

    assert {:ok, %{stream_version: 1}} = EventStore.append(start_spec)

    {:ok, pid} = Actor.start_link(Phase, stream_id)

    assert %Phase.State{status: "in_progress", terminal?: false} = Actor.current_state(pid)

    assert {:ok, %{event: %{event_type: "PhaseCompleted", stream_version: 2}}} =
             CommandRouter.handle(%{
               command_id: "phase-complete:external-winner",
               command_type: "phase.complete",
               payload: %{run_id: "run-actor-race", phase_id: "package"}
             })

    assert {:error, :phase_terminal} =
             Actor.command(
               pid,
               "phase.complete",
               %{run_id: "run-actor-race", phase_id: "package"},
               "phase-complete:stale-actor"
             )

    assert %Phase.State{status: "completed", terminal?: true} = Actor.current_state(pid)

    assert ["PhaseStarted", "PhaseCompleted"] ==
             EventStore.stream(stream_id) |> Enum.map(& &1.event_type)
  end
end
