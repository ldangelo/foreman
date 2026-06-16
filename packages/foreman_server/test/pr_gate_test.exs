defmodule ForemanServer.PrGateTest do
  use ExUnit.Case

  alias ForemanServer.{PrGate, ProjectionStore}

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "foreman-pr-gate-test-#{System.unique_integer([:positive])}")

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

  test "delayed checks progress through pending and seen_pending before stable_ready" do
    assert {:ok, %{result: %{state: "pending"}}} =
             PrGate.observe(%{
               pr_id: "1",
               run_id: "run-pr-1",
               checks: "pending",
               review: "pending"
             })

    assert {:ok, %{result: %{state: "seen_pending"}}} =
             PrGate.observe(%{
               pr_id: "1",
               run_id: "run-pr-1",
               checks: "pending",
               review: "pending"
             })

    assert ProjectionStore.snapshot().pr_gates["1"].state == "seen_pending"

    assert {:ok, %{result: %{state: "stable_ready"}}} =
             PrGate.observe(%{
               pr_id: "1",
               run_id: "run-pr-1",
               checks: "success",
               review: "approved",
               stable_for_seconds: 31
             })
  end

  test "stable ready PR revalidates immediately before merge" do
    fixture = fixture()
    assert {:ok, %{result: %{state: "stable_ready"}}} = PrGate.observe(fixture["pr_gate_state"])

    assert {:ok, %{event: event}} =
             PrGate.merge(%{
               pr_id: "42",
               run_id: "run-pr-42",
               backend: fixture["backend"],
               branch: "feature/pr-42",
               target: "main"
             })

    assert event.event_type == "PrMerged"
    assert ProjectionStore.snapshot().pr_gates["42"].state == "merged"
  end

  test "merge blocked or failed reason is visible from projected events" do
    assert {:ok, %{result: %{state: "pending"}}} =
             PrGate.observe(%{
               pr_id: "2",
               run_id: "run-pr-2",
               checks: "success",
               review: "approved",
               stable_for_seconds: 5
             })

    assert {:error, {:merge_gate_not_ready, %{observed_state: "pending"}}} =
             PrGate.merge(%{
               pr_id: "2",
               run_id: "run-pr-2",
               branch: "feature/pr-2",
               target: "main"
             })

    failure = ProjectionStore.snapshot().merge_failures["2"]
    assert failure.event_type == "MergeBlocked"
    assert failure.reason == "merge_gate_not_ready"
  end

  defp fixture do
    "test/fixtures/vcs-pr-ready-state.json"
    |> File.read!()
    |> Jason.decode!()
  end
end
