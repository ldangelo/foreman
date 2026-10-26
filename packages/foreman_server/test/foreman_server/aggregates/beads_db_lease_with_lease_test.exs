defmodule ForemanServer.Aggregates.BeadsDbLeaseWithLeaseTest do
  @moduledoc """
  Proves `BeadsDbLease.with_lease/4` releases the lease even when its
  callback raises, using the real `CommandGateway`/`CommandRouter`/Actor
  path (no fakes) — the same path `BeadsAdapter` and `BeadsWatcher` run
  every `br` call through.

  Regression for a live incident: a `BeadsWatcher` scan's synthetic
  `watcher:<project_id>:<ts>` run_id acquired the lease, its callback
  raised, and because `with_lease/4` released only on the callback's
  normal return, the lease was held forever — every subsequent
  `claim/3` (real task dispatch) queued behind it and failed with
  `{:claim_failure, :lease_timeout}` indefinitely.

  The same stranded hold, left by a server that was killed instead of
  raising (foreman-w29up), is covered by the incarnation tests below.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.CommandGateway
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Incarnation

  test "a raising callback still releases the lease for the next acquirer" do
    db_path = "/tmp/beads-lease-crash-test-#{System.unique_integer([:positive, :monotonic])}.db"

    assert_raise RuntimeError, "boom", fn ->
      BeadsDbLease.with_lease(db_path, "run-crasher", "task-crasher", fn ->
        raise "boom"
      end)
    end

    # If the lease were still held by "run-crasher", this would time out
    # after ~5s (50 polls * 100ms) and return {:error, :lease_timeout}.
    assert {:ok, :acquired} =
             BeadsDbLease.with_lease(db_path, "run-next", "task-next", fn ->
               {:ok, :acquired}
             end)
  end

  test "a thrown value from the callback still releases the lease" do
    db_path = "/tmp/beads-lease-throw-test-#{System.unique_integer([:positive, :monotonic])}.db"

    assert catch_throw(
             BeadsDbLease.with_lease(db_path, "run-thrower", "task-thrower", fn ->
               throw(:bail)
             end)
           ) == :bail

    assert {:ok, :acquired} =
             BeadsDbLease.with_lease(db_path, "run-next", "task-next", fn ->
               {:ok, :acquired}
             end)
  end

  test "a hold stranded by a server incarnation that no longer exists is taken over, not waited for" do
    db_path =
      "/tmp/beads-lease-stale-incarnation-test-#{System.unique_integer([:positive, :monotonic])}.db"

    stream = BeadsDbLease.stream_id(db_path)
    on_exit(fn -> _ = Store.delete_stream(stream, :any_version, :hard) end)

    # What a server killed mid-call leaves behind: the hold, tagged with that server's
    # incarnation, never released. `watcher:<project>:<ns>` is the id BeadsWatcher uses.
    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               type: "lease.acquire",
               command_id: "test:stranded-hold:#{stream}",
               aggregate_id: stream,
               payload: %{
                 db_path: db_path,
                 run_id: "watcher:proj:1",
                 task_id: "watcher:proj:1",
                 acquired_at_ms: System.system_time(:millisecond),
                 incarnation: "incarnation-of-the-killed-server"
               }
             })

    # The restart: the aggregate actor is gone and is rebuilt from the event store.
    :ok = Supervisor.terminate_child(ForemanServer.Aggregator, stream)
    :ok = Supervisor.delete_child(ForemanServer.Aggregator, stream)

    {rebuilt, _version} = Aggregate.load(BeadsDbLease, stream)
    assert %BeadsDbLease.Holder{run_id: "watcher:proj:1"} = rebuilt.holder

    # Queued behind the dead hold this times out after ~5s with {:error, :lease_timeout}:
    # BeadsWatcher then logs "lease_acquire failed ... skipping this read cycle" on
    # every poll and no bead is imported.
    assert {:ok, :read} =
             BeadsDbLease.with_lease(db_path, "watcher:proj:2", "watcher:proj:2", fn ->
               {:ok, :read}
             end)

    {:ok, events} = Store.read_stream_forward(stream, 0, 100)

    assert Enum.any?(events, fn event ->
             event.event_type == "BeadsDbLeaseAcquired" and
               event.data.run_id == "watcher:proj:2" and
               event.data.provenance == {:reclaimed_stale_holder, "watcher:proj:1"}
           end)

    {freed, _version} = Aggregate.load(BeadsDbLease, stream)
    assert freed.holder == nil
  end

  test "a live hold of this incarnation is never taken over, and the timeout names its holder" do
    db_path =
      "/tmp/beads-lease-live-hold-test-#{System.unique_integer([:positive, :monotonic])}.db"

    stream = BeadsDbLease.stream_id(db_path)
    on_exit(fn -> _ = Store.delete_stream(stream, :any_version, :hard) end)
    parent = self()

    holder =
      Task.async(fn ->
        BeadsDbLease.with_lease(db_path, "watcher:live:1", "watcher:live:1", fn ->
          send(parent, :holding)

          receive do
            :release -> {:ok, :done}
          end
        end)
      end)

    assert_receive :holding, 5_000

    # This waits out its ~5s poll budget behind the live holder.
    log =
      capture_log(fn ->
        assert {:error, :lease_timeout} =
                 BeadsDbLease.with_lease(db_path, "run-late", "task-late", fn ->
                   {:ok, :must_not_run}
                 end)
      end)

    assert log =~ "run_id=run-late timed out behind holder run_id=watcher:live:1"
    assert log =~ "incarnation=#{inspect(Incarnation.id())}"

    send(holder.pid, :release)
    assert {:ok, :done} = Task.await(holder, 5_000)
  end
end
