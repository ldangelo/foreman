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
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.BeadsDbLease

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
end
