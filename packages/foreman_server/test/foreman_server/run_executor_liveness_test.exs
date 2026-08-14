defmodule ForemanServer.RunExecutorLivenessTest do
  # NOTE: The Liveness GenServer is started by the application supervision
  # tree; this test exercises the public API and ETS table directly.
  use ExUnit.Case, async: false

  alias ForemanServer.RunExecutorLiveness

  setup do
    RunExecutorLiveness.clear_all()
    on_exit(fn -> RunExecutorLiveness.clear_all() end)
    :ok
  end

  describe "record/3 + lookup/2" do
    test "lookup returns :none when no entry exists" do
      assert RunExecutorLiveness.lookup("run-missing", 0) == :none
    end

    test "lookup returns :active with owner when deadline is in the future" do
      now_ms = 1_700_000_000_000
      deadline_ms = now_ms + 30_000
      owner = self()
      RunExecutorLiveness.record("run-active", owner, deadline_ms)

      assert {:active, ^owner, ^deadline_ms} =
               RunExecutorLiveness.lookup("run-active", now_ms)
    end

    test "lookup returns :active one millisecond before the deadline (strict <)" do
      now_ms = 1_700_000_000_000
      deadline_ms = now_ms + 100
      owner = self()
      RunExecutorLiveness.record("run-edge", owner, deadline_ms)

      # Strictly less than the deadline → still active.
      assert {:active, ^owner, ^deadline_ms} =
               RunExecutorLiveness.lookup("run-edge", now_ms + 99)
    end

    test "lookup returns :expired once now_ms >= deadline" do
      now_ms = 1_700_000_000_000
      deadline_ms = now_ms + 100
      owner = self()
      RunExecutorLiveness.record("run-expired", owner, deadline_ms)

      # At the deadline → expired.
      assert {:expired, ^owner, ^deadline_ms} =
               RunExecutorLiveness.lookup("run-expired", now_ms + 100)

      # Past the deadline → expired.
      assert {:expired, ^owner, ^deadline_ms} =
               RunExecutorLiveness.lookup("run-expired", now_ms + 200)
    end

    test "later record/3 overwrites the previous deadline" do
      now_ms = 1_700_000_000_000
      owner = self()
      RunExecutorLiveness.record("run-overwrite", owner, now_ms + 1_000)
      deadline_ms = now_ms + 5_000
      RunExecutorLiveness.record("run-overwrite", owner, deadline_ms)

      assert {:active, ^owner, ^deadline_ms} =
               RunExecutorLiveness.lookup("run-overwrite", now_ms + 2_000)
    end

    test "later record/3 with a new owner replaces the stored owner" do
      now_ms = 1_700_000_000_000
      deadline_ms = now_ms + 5_000

      original_owner = self()
      RunExecutorLiveness.record("run-replaced", original_owner, deadline_ms)

      # Respawned executor records under its own PID.
      replacement_owner =
        spawn(fn ->
          :ok
        end)

      ref = Process.monitor(replacement_owner)
      assert_receive {:DOWN, ^ref, :process, ^replacement_owner, :normal}, 1_000

      # The replacement records its own deadline under its own PID,
      # overwriting the predecessor's entry. The original_owner is
      # no longer the stored owner.
      RunExecutorLiveness.record("run-replaced", replacement_owner, deadline_ms + 1_000)

      assert {:active, ^replacement_owner, _} =
               RunExecutorLiveness.lookup("run-replaced", now_ms)
    end
  end

  describe "clear/2 (owner-conditional)" do
    test "removes the entry when the stored owner matches" do
      now_ms = 1_700_000_000_000
      owner = self()
      RunExecutorLiveness.record("run-clear-owned", owner, now_ms + 1_000)
      assert {:active, ^owner, _} = RunExecutorLiveness.lookup("run-clear-owned", now_ms)

      assert :ok = RunExecutorLiveness.clear("run-clear-owned", owner)
      assert RunExecutorLiveness.lookup("run-clear-owned", now_ms) == :none
    end

    test "is a no-op when the stored owner does not match" do
      now_ms = 1_700_000_000_000
      original_owner = self()
      RunExecutorLiveness.record("run-clear-mismatch", original_owner, now_ms + 1_000)

      # An intruder (some other PID) tries to clear. It must not
      # touch the entry because the owner check fails.
      intruder = spawn(fn -> :ok end)
      ref = Process.monitor(intruder)
      assert_receive {:DOWN, ^ref, :process, ^intruder, :normal}, 1_000

      # The intruder is now dead; clear/2 with its PID must still be
      # a no-op because the stored owner is the test process, not the
      # intruder.
      assert :ok = RunExecutorLiveness.clear("run-clear-mismatch", intruder)

      assert {:active, ^original_owner, _} =
               RunExecutorLiveness.lookup("run-clear-mismatch", now_ms)
    end
  end

  describe "clear/1 (admin)" do
    test "removes the recorded entry regardless of owner" do
      now_ms = 1_700_000_000_000
      owner = self()
      RunExecutorLiveness.record("run-clear-admin", owner, now_ms + 1_000)
      assert {:active, ^owner, _} = RunExecutorLiveness.lookup("run-clear-admin", now_ms)

      RunExecutorLiveness.clear("run-clear-admin")
      assert RunExecutorLiveness.lookup("run-clear-admin", now_ms) == :none
    end

    test "is a no-op when no entry exists" do
      assert :ok = RunExecutorLiveness.clear("run-never-recorded")
    end
  end

  describe "size/0 + clear_all/0" do
    test "tracks the number of recorded entries" do
      assert RunExecutorLiveness.size() == 0
      RunExecutorLiveness.record("a", self(), 1)
      RunExecutorLiveness.record("b", self(), 2)
      assert RunExecutorLiveness.size() == 2
      RunExecutorLiveness.clear_all()
      assert RunExecutorLiveness.size() == 0
    end
  end
end
