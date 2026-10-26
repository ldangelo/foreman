defmodule ForemanServer.Aggregates.BeadsDbLeaseCallerDeathTest do
  @moduledoc """
  foreman-8qge. A `BeadsDbLease.with_lease/4` caller that ends without running its `after`
  block (`Process.exit(pid, :kill)`, a supervisor's `:shutdown` of a child that does not trap
  exits, a linked process crashing) used to keep the lease until the VM restarted: the hold names
  this VM's incarnation, this VM is alive, so no later call could call the hold dead and every
  other caller of that Beads database queued behind it until `:lease_timeout`. A dead WAITER was
  worse: it stayed in the queue and was promoted to a hold nobody would release.

  Real `CommandGateway`/`CommandRouter`/Actor path and real processes killed with real exit
  signals, no fakes. Every test names the processes it kills, so nothing here depends on the
  lease being free of other tests' keepers.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.BeadsDbLease
  alias ForemanServer.Aggregates.BeadsDbLease.{Keeper, KeeperSupervisor}
  alias ForemanServer.CommandGateway
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.Incarnation
  alias ForemanServer.TestSupport.{Eventually, LeaseKeepers}

  setup do
    db_path =
      "/tmp/beads-lease-caller-death-#{System.unique_integer([:positive, :monotonic])}.db"

    stream = BeadsDbLease.stream_id(db_path)
    # Not linked: `on_exit/1` runs after the test process is gone.
    {:ok, tracked} = Agent.start(fn -> [] end)

    on_exit(fn ->
      # Whatever a failed assertion left running dies first, and its keepers finish before the
      # stream goes: a keeper dispatching into a deleted stream would recreate it.
      pids = Agent.get(tracked, & &1)
      Agent.stop(tracked)
      Enum.each(pids, &Process.exit(&1, :kill))
      Eventually.await(fn -> Enum.all?(pids, &(keepers_for(&1) == [])) end)

      # A test that never wrote to the stream has nothing to delete (and deleting logs a warning).
      with {:ok, _events} <- Store.read_stream_forward(stream, 0, 1),
           do: Store.delete_stream(stream, :any_version, :hard)
    end)

    %{db_path: db_path, stream: stream, tracked: tracked}
  end

  describe "a holder that dies inside its callback" do
    for signal <- [:kill, :shutdown] do
      test "(#{inspect(signal)}) gives the lease to the next waiter", ctx do
        %{db_path: db_path} = ctx
        holder = start_holder(ctx, "run-holder")
        start_waiter(ctx, "run-next")

        log =
          capture_log(fn ->
            kill(holder, unquote(signal))
            assert_receive {:finished, "run-next", result}, 10_000
            assert result == {:ok, :ran}
          end)

        assert log =~ "run_id=run-holder"

        assert_free(db_path)

        assert Enum.any?(events(ctx), fn {type, data} ->
                 type == "BeadsDbLeaseTransferred" and data.released_run_id == "run-holder" and
                   data.acquired_run_id == "run-next" and data.reason == :caller_down
               end)
      end
    end

    test "frees a lease nobody is waiting for", %{db_path: db_path} = ctx do
      holder = start_holder(ctx, "run-holder")

      capture_log(fn -> kill(holder, :kill) end)

      assert_free(db_path)

      assert {:ok, :acquired} =
               BeadsDbLease.with_lease(db_path, "run-next", "task-next", fn ->
                 {:ok, :acquired}
               end)

      assert Enum.any?(events(ctx), fn {type, data} ->
               type == "BeadsDbLeaseReleased" and data.run_id == "run-holder" and
                 data.reason == :caller_down
             end)
    end
  end

  describe "a waiter that dies in the queue" do
    test "is dropped from the queue and is never promoted", %{db_path: db_path} = ctx do
      holder = start_holder(ctx, "run-holder")
      dead = start_waiter(ctx, "run-dead")
      start_waiter(ctx, "run-live")

      log = capture_log(fn -> kill(dead, :kill) end)

      assert log =~ "run_id=run-dead"
      assert waiter_ids(db_path) == ["run-live"]
      # The holder is a live process and keeps its lease.
      assert %BeadsDbLease.Holder{run_id: "run-holder"} = lease_state(db_path).holder

      send(holder, :release)
      assert_receive {:finished, "run-live", {:ok, :ran}}, 10_000

      assert_free(db_path)

      refute Enum.any?(events(ctx), fn {type, data} ->
               type == "BeadsDbLeaseTransferred" and data.acquired_run_id == "run-dead"
             end)
    end
  end

  describe "a holder and the waiter queued behind it that die in one crash" do
    for order <- [:holder_first, :waiter_first] do
      test "(#{order}) leave the lease to the live waiter behind them",
           %{db_path: db_path} = ctx do
        holder = start_holder(ctx, "run-holder")
        dead_waiter = start_waiter(ctx, "run-dead-waiter")
        start_waiter(ctx, "run-live")

        victims =
          case unquote(order) do
            :holder_first -> [holder, dead_waiter]
            :waiter_first -> [dead_waiter, holder]
          end

        capture_log(fn ->
          Enum.each(victims, &Process.exit(&1, :kill))
          assert_receive {:finished, "run-live", result}, 10_000
          assert result == {:ok, :ran}
        end)

        assert_free(db_path)
      end
    end
  end

  describe "the keeper is armed before the lease is touched" do
    test "a caller killed while its lease.acquire still waits at the actor leaves no hold",
         %{db_path: db_path, stream: stream} = ctx do
      # Starts the lease actor; releasing a lease nobody holds appends nothing.
      assert {:ok, nil} = dispatch_release(db_path, "run-nobody")
      [{actor, _}] = Registry.lookup(ForemanServer.AggregateRegistry, stream)

      :ok = :sys.suspend(actor)

      try do
        caller =
          spawn_tracked(ctx, fn ->
            BeadsDbLease.with_lease(db_path, "run-in-flight", "run-in-flight", fn ->
              {:ok, :ran}
            end)
          end)

        # Its `lease.acquire` is parked in the suspended actor's mailbox: nothing is held yet.
        Eventually.await(fn -> queued(actor, "lease.acquire") == 1 end,
          message: "the lease.acquire reached the actor"
        )

        assert [_keeper] = keepers_for(caller),
               "the caller has no keeper although its lease.acquire is already on its way"

        [keeper] = keepers_for(caller)
        ref = Process.monitor(keeper)

        capture_log(fn ->
          Process.exit(caller, :kill)
          # The keeper's own commands queue behind the acquire; the actor works them off in order.
          :ok = :sys.resume(actor)
          assert_receive {:DOWN, ^ref, :process, ^keeper, :normal}, 5_000
        end)
      after
        # Idempotent when the happy path already resumed it; a failed assertion must not leave
        # the actor suspended for the next test.
        _ = :sys.resume(actor)
      end

      # The acquire landed after its caller's death, and the keeper still gave it back.
      assert_free(db_path)

      assert Enum.any?(events(ctx), fn {type, data} ->
               type == "BeadsDbLeaseAcquired" and data.run_id == "run-in-flight"
             end)
    end
  end

  describe "the order of a keeper's cleanup" do
    test "takes a dead waiter out of the queue before it releases, so no release in between promotes it",
         %{db_path: db_path, stream: stream} = ctx do
      holder = start_holder(ctx, "run-holder")
      dead = start_waiter(ctx, "run-dead")
      [{actor, _}] = Registry.lookup(ForemanServer.AggregateRegistry, stream)
      [keeper] = keepers_for(dead)
      ref = Process.monitor(keeper)

      :ok = :sys.suspend(actor)

      try do
        capture_log(fn ->
          Process.exit(dead, :kill)

          # The keeper's first command is parked at the actor, and the holder's own release lines
          # up behind it: the interleaving that a release-first cleanup loses to.
          Eventually.await(fn -> queued(actor, "lease.remove_waiter") == 1 end,
            message: "the keeper's first command reached the actor"
          )

          send(holder, :release)

          Eventually.await(fn -> queued(actor, "lease.release") == 1 end,
            message: "the holder's release reached the actor"
          )

          :ok = :sys.resume(actor)
          assert_receive {:DOWN, ^ref, :process, ^keeper, :normal}, 5_000
        end)
      after
        _ = :sys.resume(actor)
      end

      # A keeper that released first would have found the holder's release promote the dead waiter
      # in between, and its removal would then have found nobody to remove.
      assert_free(db_path)
    end
  end

  describe "a cleanup that arrives after the lease moved on" do
    test "does not drop the hold of the run that has it now", %{db_path: db_path} = ctx do
      a = start_holder(ctx, "run-a")
      assert [keeper_a] = keepers_for(a)

      # The keeper is slow: it learns of A's death only after the lease has moved on.
      :ok = :sys.suspend(keeper_a)
      Process.exit(a, :kill)

      # What moves the lease on without the keeper: an operator-style release of A's hold,
      # then B taking it.
      assert {:ok, %{}} = dispatch_release(db_path, "run-a")
      b = start_holder(ctx, "run-b")
      assert %BeadsDbLease.Holder{run_id: "run-b"} = lease_state(db_path).holder

      ref = Process.monitor(keeper_a)
      :ok = :sys.resume(keeper_a)
      assert_receive {:DOWN, ^ref, :process, ^keeper_a, :normal}, 5_000

      # The late `lease.release` for run-a found another run's hold and left it alone.
      assert %BeadsDbLease.Holder{run_id: "run-b"} = lease_state(db_path).holder

      refute Enum.any?(events(ctx), fn {_type, data} -> Map.get(data, :reason) == :caller_down end)

      send(b, :release)
      Eventually.await(fn -> lease_state(db_path).holder == nil end)
    end
  end

  describe "a holder that is alive" do
    # Longer than the waiter's poll interval (100ms) and than the keeper's retry interval (1s), and
    # inside the waiter's own budget (50 polls, about 5s): a timer that gave up a live hold would
    # fire within it. There is no TTL by design: a `br` call may legitimately run long.
    @live_window_ms 2_000

    test "keeps its lease for as long as it runs: nothing gives it up on a timer",
         %{db_path: db_path} = ctx do
      holder = start_holder(ctx, "run-long")
      assert [keeper] = keepers_for(holder)
      keeper_ref = Process.monitor(keeper)
      start_waiter(ctx, "run-patient")

      # Through the whole window the waiter stays queued and the keeper stays armed.
      refute_receive {:finished, "run-patient", _}, @live_window_ms
      refute_receive {:DOWN, ^keeper_ref, :process, ^keeper, _}, 0

      # The holder still holds, and the stream records neither a release nor a transfer.
      assert %BeadsDbLease.Holder{run_id: "run-long"} = lease_state(db_path).holder
      assert waiter_ids(db_path) == ["run-patient"]
      assert event_types(ctx) == ["BeadsDbLeaseAcquired", "BeadsDbLeaseWaiterRegistered"]

      # It finishes on its own, and only then does the waiter get the lease.
      send(holder, :release)
      assert_receive {:finished, "run-long", {:ok, :released_by_test}}, 5_000
      assert_receive {:finished, "run-patient", {:ok, :ran}}, 10_000

      assert_free(db_path)

      refute Enum.any?(events(ctx), fn {_type, data} -> Map.get(data, :reason) == :caller_down end)
    end
  end

  describe "the normal path" do
    test "keeps one keeper for the call and leaves none behind", %{db_path: db_path} = ctx do
      assert {:ok, :done} =
               BeadsDbLease.with_lease(db_path, "run-normal", "task-normal", fn ->
                 assert [_keeper] = keepers_for(self())
                 {:ok, :done}
               end)

      assert keepers_for(self()) == []
      assert event_types(ctx) == ["BeadsDbLeaseAcquired", "BeadsDbLeaseReleased"]
    end

    test "a caller that exits right after its call causes no cleanup",
         %{db_path: db_path} = ctx do
      {pid, ref} =
        spawn_monitor(fn ->
          {:ok, :done} =
            BeadsDbLease.with_lease(db_path, "run-short", "task-short", fn -> {:ok, :done} end)
        end)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000

      assert keepers_for(pid) == []
      assert event_types(ctx) == ["BeadsDbLeaseAcquired", "BeadsDbLeaseReleased"]

      refute Enum.any?(events(ctx), fn {_type, data} -> Map.get(data, :reason) == :caller_down end)
    end

    test "a callback that raises leaves no keeper behind and still frees the lease",
         %{db_path: db_path} do
      assert_raise RuntimeError, "boom", fn ->
        BeadsDbLease.with_lease(db_path, "run-crasher", "task-crasher", fn -> raise "boom" end)
      end

      assert keepers_for(self()) == []
      assert_free(db_path)
    end

    test "a keeper that ended during the call does not break it", %{db_path: db_path} do
      assert {:ok, :done} =
               BeadsDbLease.with_lease(db_path, "run-lonely", "task-lonely", fn ->
                 assert [keeper] = keepers_for(self())
                 ref = Process.monitor(keeper)
                 Process.exit(keeper, :kill)
                 assert_receive {:DOWN, ^ref, :process, ^keeper, :killed}, 5_000
                 {:ok, :done}
               end)

      assert_free(db_path)
    end
  end

  describe "without a keeper supervisor" do
    test "the call fails loudly and takes no lease", %{db_path: db_path} = ctx do
      :ok = Supervisor.terminate_child(ForemanServer.Application, KeeperSupervisor)

      try do
        assert {:error, {:lease_keeper_unavailable, _reason}} =
                 BeadsDbLease.with_lease(db_path, "run-x", "task-x", fn ->
                   flunk("the callback must not run without a keeper")
                 end)

        assert events(ctx) == []
      after
        {:ok, _pid} = Supervisor.restart_child(ForemanServer.Application, KeeperSupervisor)
      end
    end
  end

  describe "a cleanup that cannot be dispatched" do
    setup %{db_path: db_path, stream: stream} do
      hold(db_path, "run-stuck")
      [{actor, _}] = Registry.lookup(ForemanServer.AggregateRegistry, stream)
      caller = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(caller, :kill) end)

      %{actor: actor, caller: caller}
    end

    test "is retried until it lands",
         %{db_path: db_path, actor: actor, caller: caller} = ctx do
      :ok = :sys.suspend(actor)

      try do
        {:ok, keeper} =
          Keeper.watch(caller, db_path, "run-stuck",
            call_timeout_ms: 50,
            retry_interval_ms: 20,
            max_attempts: 200
          )

        ref = Process.monitor(keeper)

        capture_log(fn ->
          Process.exit(caller, :kill)

          # The first attempt timed out and the keeper tried again: two removals wait at the actor.
          Eventually.await(fn -> queued(actor, "lease.remove_waiter") >= 2 end,
            message: "the keeper retried against the suspended actor"
          )

          :ok = :sys.resume(actor)
          assert_receive {:DOWN, ^ref, :process, ^keeper, :normal}, 5_000
        end)
      after
        _ = :sys.resume(actor)
      end

      assert_free(db_path)

      assert Enum.any?(events(ctx), fn {type, data} ->
               type == "BeadsDbLeaseReleased" and data.run_id == "run-stuck" and
                 data.reason == :caller_down
             end)
    end

    test "is given up on loudly once its attempts are spent",
         %{db_path: db_path, actor: actor, caller: caller} do
      :ok = :sys.suspend(actor)

      try do
        {:ok, keeper} =
          Keeper.watch(caller, db_path, "run-stuck",
            call_timeout_ms: 30,
            retry_interval_ms: 10,
            max_attempts: 2
          )

        ref = Process.monitor(keeper)

        log =
          capture_log(fn ->
            Process.exit(caller, :kill)
            assert_receive {:DOWN, ^ref, :process, ^keeper, :normal}, 5_000
          end)

        assert log =~ "could not give back"
        assert log =~ "run_id=run-stuck"
        assert log =~ "2 attempts"
      after
        _ = :sys.resume(actor)
      end

      # The hold is still there: the keeper reported the failure instead of pretending.
      assert %BeadsDbLease.Holder{run_id: "run-stuck"} = lease_state(db_path).holder
    end
  end

  # -- helpers ---------------------------------------------------------------------------------

  # A process in `with_lease/4` that holds the lease until it is sent `:release`.
  defp start_holder(ctx, run_id) do
    parent = self()

    pid =
      spawn_tracked(ctx, fn ->
        result =
          BeadsDbLease.with_lease(ctx.db_path, run_id, run_id, fn ->
            send(parent, {:holding, run_id, self()})

            receive do
              :release -> {:ok, :released_by_test}
            end
          end)

        send(parent, {:finished, run_id, result})
      end)

    assert_receive {:holding, ^run_id, ^pid}, 5_000
    pid
  end

  # A process in `with_lease/4` queued behind the current holder, whose callback returns at once.
  defp start_waiter(ctx, run_id) do
    parent = self()

    pid =
      spawn_tracked(ctx, fn ->
        result =
          BeadsDbLease.with_lease(ctx.db_path, run_id, run_id, fn ->
            send(parent, {:ran, run_id})
            {:ok, :ran}
          end)

        send(parent, {:finished, run_id, result})
      end)

    Eventually.await(fn -> run_id in waiter_ids(ctx.db_path) end,
      message: "#{run_id} is queued behind the holder"
    )

    pid
  end

  defp spawn_tracked(%{tracked: tracked}, fun) do
    pid = spawn(fun)
    Agent.update(tracked, &[pid | &1])
    pid
  end

  # Ends `victim` with an exit signal it cannot run an `after` block for, then waits for each of
  # its keepers to finish: a keeper logs what it cleared before it stops, so the log is complete
  # and the lease entries are already gone when this returns.
  defp kill(victim, signal) do
    monitors = for keeper <- keepers_for(victim), do: {keeper, Process.monitor(keeper)}

    Process.exit(victim, signal)

    for {keeper, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^keeper, :normal}, 5_000
    end

    :ok
  end

  # The keepers of the calls `caller` is in.
  defp keepers_for(caller), do: LeaseKeepers.for_caller(caller)

  # How many commands of `type` wait in `actor`'s mailbox.
  defp queued(actor, type) do
    {:messages, messages} = Process.info(actor, :messages)
    Enum.count(messages, &match?({:"$gen_call", _from, {:command, %{type: ^type}}}, &1))
  end

  defp lease_state(db_path) do
    {state, _version} = Aggregate.load(BeadsDbLease, BeadsDbLease.stream_id(db_path))
    state
  end

  defp waiter_ids(db_path),
    do: db_path |> lease_state() |> BeadsDbLease.waiters() |> Enum.map(& &1.run_id)

  defp assert_free(db_path) do
    state = lease_state(db_path)
    assert state.holder == nil, "the lease is still held: #{inspect(state.holder)}"
    assert state.waiters == [], "waiters are still queued: #{inspect(state.waiters)}"
  end

  defp events(%{stream: stream}) do
    case Store.read_stream_forward(stream, 0, 1_000) do
      {:ok, events} -> Enum.map(events, &{&1.event_type, &1.data})
      {:error, :stream_not_found} -> []
    end
  end

  defp event_types(ctx), do: ctx |> events() |> Enum.map(&elem(&1, 0))

  # A hold taken straight through the command path, as `with_lease/4` takes it, without a
  # process behind it.
  defp hold(db_path, run_id) do
    assert {:ok, %{}} =
             CommandGateway.dispatch_system(%{
               type: "lease.acquire",
               command_id: "test:caller-death:hold:#{db_path}:#{run_id}",
               aggregate_id: BeadsDbLease.stream_id(db_path),
               payload: %{
                 db_path: db_path,
                 run_id: run_id,
                 task_id: run_id,
                 acquired_at_ms: System.system_time(:millisecond),
                 incarnation: Incarnation.id()
               }
             })
  end

  defp dispatch_release(db_path, run_id) do
    CommandGateway.dispatch_system(%{
      type: "lease.release",
      command_id:
        "test:caller-death:release:#{db_path}:#{run_id}:#{System.unique_integer([:positive])}",
      aggregate_id: BeadsDbLease.stream_id(db_path),
      payload: %{
        db_path: db_path,
        run_id: run_id,
        released_at_ms: System.system_time(:millisecond),
        reason: :test_release
      }
    })
  end
end
