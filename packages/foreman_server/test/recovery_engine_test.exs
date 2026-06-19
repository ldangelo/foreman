defmodule ForemanServer.RecoveryEngineTest do
  use ExUnit.Case

  alias ForemanServer.{ProjectionStore, RecoveryEngine}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-recovery-test-#{System.unique_integer([:positive])}")

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

  test "stale checkpoint fixture observes external worker before restarting" do
    fixture = fixture()

    assert {:ok, %{decision: :restart}} = RecoveryEngine.reconcile(fixture)

    event_types = Enum.map(ProjectionStore.snapshot().recovery_events, & &1.event_type)
    assert event_types == ["ExternalWorkerObserved", "WorkerRestarted"]
  end

  test "fresh matching heartbeat reattaches instead of restarting" do
    fresh = %{
      run_id: "run-reattach",
      phase_id: "qa",
      worker_id: "worker-2",
      heartbeat_age_seconds: 5,
      heartbeat: %{run_id: "run-reattach", phase_id: "qa", worker_id: "worker-2"},
      external_state: %{worker_alive: true},
      attach: %{session_path: "/tmp/session.jsonl"},
      checkpoint: %{safe: true},
      restart_policy: %{allow_restart: true}
    }

    assert {:ok, %{decision: :reattach}} = RecoveryEngine.reconcile(fresh)
    event_types = Enum.map(ProjectionStore.snapshot().recovery_events, & &1.event_type)
    assert event_types == ["ExternalWorkerObserved", "WorkerReattached"]
  end

  test "unresolved external conflicts produce NeedsOperator" do
    conflict = %{
      run_id: "run-conflict",
      phase_id: "reviewer",
      worker_id: "worker-3",
      heartbeat_age_seconds: 999,
      heartbeat: %{run_id: "run-conflict", phase_id: "reviewer", worker_id: "worker-3"},
      external_state: %{worker_alive: false, worktree_exists: false, branch_exists: true},
      checkpoint: %{safe: false},
      restart_policy: %{allow_restart: false},
      conflicts: ["missing_worktree", "branch_exists"]
    }

    assert {:ok, %{decision: :needs_operator}} = RecoveryEngine.reconcile(conflict)
    [_, needs_operator] = ProjectionStore.snapshot().recovery_events
    assert needs_operator.event_type == "NeedsOperator"
    assert needs_operator.conflicts == ["missing_worktree", "branch_exists"]
  end

  defp fixture do
    "test/fixtures/worker-heartbeat-stale-and-checkpoint.json"
    |> File.read!()
    |> Jason.decode!()
  end
end
