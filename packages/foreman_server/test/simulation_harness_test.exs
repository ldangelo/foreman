defmodule ForemanServer.SimulationHarnessTest do
  use ExUnit.Case

  alias ForemanServer.SimulationHarness

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "foreman-simulation-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    Application.stop(:foreman_server)
    Application.put_env(:foreman_server, :event_log_path, Path.join(tmp_dir, "events.term.log"))
    assert :ok = Application.start(:foreman_server)

    on_exit(fn ->
      Application.stop(:foreman_server)
      Application.delete_env(:foreman_server, :event_log_path)
      File.rm_rf!(tmp_dir)
      Application.start(:foreman_server)
    end)

    :ok
  end

  test "run state transitions simulate in memory with event assertions" do
    assert {:ok, result} =
             SimulationHarness.run([
               %{action: :start_run, run_id: "sim-run", phases: ["dev", "qa"]},
               %{action: :phase_pass, run_id: "sim-run"},
               %{action: :phase_pass, run_id: "sim-run"}
             ])

    run = result.projection.runs["sim-run"]
    assert run.status == "completed"
    assert run.phase_status == %{"dev" => "completed", "qa" => "completed"}
    assert Enum.count(result.events) >= 5
  end

  test "worker failure simulation emits deterministic recovery events" do
    assert {:ok, result} =
             SimulationHarness.run([
               %{
                 action: :worker_failure,
                 run_id: "sim-recovery",
                 phase_id: "qa",
                 worker_id: "worker-1",
                 reason: "heartbeat_stale",
                 recovery_action: "restart_phase"
               }
             ])

    assert Enum.map(result.projection.recovery_events, & &1.event_type) == [
             "WorkerFailureSimulated",
             "WorkerRecoveryRequired"
           ]

    assert hd(result.projection.recovery_events).reason == "heartbeat_stale"
  end

  test "supervised readiness API avoids arbitrary subprocess sleeps" do
    assert %{ok: true, supervised: supervised} = SimulationHarness.readiness()
    assert supervised.event_store == true
    assert supervised.projection_store == true
    assert supervised.scheduler == true

    assert {:ok, %{ready: %{ok: true}}} = SimulationHarness.run([%{action: :server_ready}])
  end
end
