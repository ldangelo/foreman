defmodule ForemanServer.Workflow.BrBvLeaseConcurrencyTest do
  @moduledoc """
  Lease-contract integration test: two `RunAdmission.start/3` calls
  against the same Beads DB serialize through the per-DB lease
  aggregate.

  Asserts, against the live event store:

    * One and only one `BeadsDbLeaseAcquired` event is appended (for
      whichever run races first).
    * One and only one `BeadsDbLeaseWaiterRegistered` event is appended
      (for the other run).
    * Releasing the holder emits exactly one `BeadsDbLeaseTransferred`
      event whose `released_run_id` is the prior holder and
      `acquired_run_id` is the prior waiter.
    * Releasing the newly-promoted holder emits one
      `BeadsDbLeaseReleased` event for that run.
    * No spurious acquisitions, registrations, or releases occur.

  Scope (documented): the lease governs only Foreman's admission path.
  External `br` writers and `bv --robot-plan` invocations are NOT
  protected — they must observe single-writer discipline themselves.
  See `AGENTS.md` §"Per-DB Beads lease".
  """
  use ExUnit.Case, async: false

  alias EventStore.RecordedEvent
  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.Aggregator
  alias ForemanServer.Aggregate.Actor
  alias ForemanServer.CommandGateway
  alias ForemanServer.EventStore, as: Store

  @stream_prefix "beads_db_lease:"

  setup do
    :ok
  end

  test "two parallel admissions serialize through the lease with a real registered project" do
    project_id = "br-bv-conc-#{System.unique_integer([:positive])}"
    db_path = "/private/tmp/conc-#{System.unique_integer([:positive])}/beads.db"
    run_a = "run-A-#{System.unique_integer([:positive])}"
    run_b = "run-B-#{System.unique_integer([:positive])}"
    task_a = "task-A-#{System.unique_integer([:positive])}"
    task_b = "task-B-#{System.unique_integer([:positive])}"

    register_project!(project_id, db_path)

    payload_a = %{
      run_id: run_a,
      task_id: task_a,
      workflow_snapshot: %{implementation: %{beads_database_path: db_path}}
    }

    payload_b = %{
      run_id: run_b,
      task_id: task_b,
      workflow_snapshot: %{implementation: %{beads_database_path: db_path}}
    }

    ta = Task.async(fn -> ForemanServer.RunAdmission.start(project_id, payload_a, 5_000) end)
    tb = Task.async(fn -> ForemanServer.RunAdmission.start(project_id, payload_b, 5_000) end)
    result_a = Task.await(ta, 5_000)
    result_b = Task.await(tb, 5_000)

    decisions = classify(result_a) ++ classify(result_b)

    assert Enum.count(decisions, &(&1 == :proceed)) == 1,
           "expected exactly one :proceed, got #{inspect(decisions)}"

    assert Enum.count(decisions, &(&1 == :queued)) == 1,
           "expected exactly one :queued, got #{inspect(decisions)}"

    {:ok, pid} = Aggregator.start_aggregate(BeadsDbLease, @stream_prefix <> db_path)
    state = Actor.get_state(pid)

    holder_run =
      case state.holder do
        %BeadsDbLease.Holder{run_id: r} -> r
        nil -> nil
      end

    assert holder_run in [run_a, run_b],
           "holder must be one of the two requesters, got #{inspect(holder_run)}"

    waiter_runs = Enum.map(state.waiters, & &1.run_id)
    other_run = if holder_run == run_a, do: run_b, else: run_a

    assert waiter_runs == [other_run],
           "waiters must be exactly the non-holder requester, got #{inspect(waiter_runs)}"

    acquired = lease_events(db_path, "BeadsDbLeaseAcquired")
    waiters_registered = lease_events(db_path, "BeadsDbLeaseWaiterRegistered")

    assert length(acquired) == 1,
           "expected one BeadsDbLeaseAcquired event, got #{length(acquired)}"

    assert length(waiters_registered) == 1,
           "expected one BeadsDbLeaseWaiterRegistered event, got #{length(waiters_registered)}"

    release_lease!(db_path, holder_run)
    transferred = wait_for_event(db_path, "BeadsDbLeaseTransferred", 1_000)

    assert transferred != nil, "expected a BeadsDbLeaseTransferred event"
    assert transferred.data.released_run_id == holder_run
    assert transferred.data.acquired_run_id == other_run

    release_lease!(db_path, other_run)
    released = wait_for_event(db_path, "BeadsDbLeaseReleased", 1_000)

    assert released != nil, "expected a BeadsDbLeaseReleased event"

    assert released.data.run_id == other_run,
           "BeadsDbLeaseReleased.run_id mismatch"

    assert length(lease_events(db_path, "BeadsDbLeaseAcquired")) == 1
    assert length(lease_events(db_path, "BeadsDbLeaseWaiterRegistered")) == 1
    assert length(lease_events(db_path, "BeadsDbLeaseTransferred")) == 1
    assert length(lease_events(db_path, "BeadsDbLeaseReleased")) == 1
  end

  # --- helpers ----------------------------------------------------------

  defp classify({:ok, :queued}), do: [:queued]
  defp classify({:ok, _}), do: [:proceed]
  defp classify({:error, _}), do: [:error]
  defp classify(_), do: [:unexpected]

  defp register_project!(project_id, db_path) do
    worktree_root = "/tmp/conc-projects/#{project_id}"
    File.mkdir_p!(worktree_root)

    cmd = %{
      type: "project.register",
      command_id: "test:br-bv-conc:register:#{project_id}",
      aggregate_id: "project:#{project_id}",
      payload: %{
        project_id: project_id,
        path: worktree_root,
        name: "conc-#{project_id}",
        workflow_type: "implement-trd-beads",
        workflow: "implement-trd-beads",
        task_provider: %{provider: "beads", database_path: db_path},
        trd_path: "docs/TRD/TRD-2026-3d41f677-add-full-vcs-worktree-support-configured-via-wor.md"
      }
    }

    case CommandGateway.dispatch_system(cmd, 5_000) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("project.register failed: #{inspect(reason)}")
    end
  end

  defp release_lease!(db_path, run_id) do
    cmd = %{
      type: "lease.release",
      command_id:
        "test:br-bv-conc:release:#{db_path}:#{run_id}:#{System.unique_integer([:positive])}",
      aggregate_id: @stream_prefix <> db_path,
      payload: %{
        db_path: db_path,
        run_id: run_id,
        released_at_ms: System.system_time(:millisecond),
        reason: "test_release"
      }
    }

    case CommandGateway.dispatch_system(cmd, 5_000) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("lease.release failed: #{inspect(reason)}")
    end
  end

  defp lease_events(db_path, event_type) do
    stream_id = @stream_prefix <> db_path

    case Store.read_stream_forward(stream_id, 0, 99_999_999) do
      {:ok, events} ->
        Enum.filter(events, fn %RecordedEvent{event_type: t} -> t == event_type end)

      {:error, :stream_not_found} ->
        []

      {:error, reason} ->
        flunk("read_stream_forward failed for #{stream_id}: #{inspect(reason)}")
    end
  end

  defp wait_for_event(db_path, event_type, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      Process.sleep(20)
      lease_events(db_path, event_type)
    end)
    |> Stream.take_while(fn _ -> System.monotonic_time(:millisecond) < deadline end)
    |> Enum.find(fn events -> events != [] end)
    |> case do
      nil -> nil
      [event | _] -> event
    end
  end
end
