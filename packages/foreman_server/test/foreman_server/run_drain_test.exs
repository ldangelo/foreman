defmodule ForemanServer.RunDrainTest do
  @moduledoc """
  The store/run-slot resets must not leave a previous test's run machinery
  running (see `ForemanServer.TestSupport.RunDrain`): a leftover executor that
  finishes after the reset hits `:project_not_found`, races the
  `run_slots:global` actor kill, and emits terminal events about tasks the
  freshly reset store has never seen.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.TestSupport.{Eventually, ProjectionStoreReset, RunDrain, RunSlotsReset}
  alias ForemanServer.Workflow.RunSupervisor

  # Stands in for a RunExecutor that outlived its test: a long-lived child of
  # the real RunSupervisor.
  defp start_leftover_executor do
    {:ok, pid} =
      DynamicSupervisor.start_child(RunSupervisor, %{
        id: :leftover,
        start: {Agent, :start_link, [fn -> :running end]},
        restart: :temporary
      })

    pid
  end

  defmodule SlowBarrier do
    use GenServer

    def start_link({name, test}), do: GenServer.start_link(__MODULE__, test, name: name)
    def init(test), do: {:ok, test}

    def handle_info(:work, test) do
      Process.sleep(100)
      send(test, :work_done)
      {:noreply, test}
    end
  end

  # What the Dispatcher does with a `TaskDispatched` it has not got to yet: handling the queued
  # message STARTS an executor. The handler parks until the test releases it, so the message is
  # handled while a `drain!/1` is flushing this process, never before.
  defmodule StartingBarrier do
    use GenServer

    def start_link({name, test}), do: GenServer.start_link(__MODULE__, test, name: name)
    def init(test), do: {:ok, test}

    def handle_info(:work, test) do
      receive do
        :release -> :ok
      end

      {:ok, pid} =
        DynamicSupervisor.start_child(ForemanServer.Workflow.RunSupervisor, %{
          id: :started_by_barrier,
          start: {Agent, :start_link, [fn -> :running end]},
          restart: :temporary
        })

      send(test, {:executor_started, pid})
      {:noreply, test}
    end
  end

  # `drain!/1` flushes a barrier with `:sys.get_state/2`: the request is queued in the barrier's
  # mailbox behind whatever it is busy with.
  defp flush_requested?(pid) do
    {:messages, messages} = Process.info(pid, :messages)
    Enum.any?(messages, &match?({:system, _from, :get_state}, &1))
  end

  test "ProjectionStoreReset.reset!/0 stops executors left behind by an earlier test" do
    pid = start_leftover_executor()
    assert Process.alive?(pid)

    ProjectionStoreReset.reset!()

    refute Process.alive?(pid)
    assert [] = RunSupervisor.which_runs()
  end

  test "RunSlotsReset.reset!/0 stops executors before it kills the run_slots actor" do
    pid = start_leftover_executor()

    RunSlotsReset.reset!()

    refute Process.alive?(pid)
  end

  test "drain!/1 returns only after the barrier processes had handled queued work" do
    name = :run_drain_test_barrier
    start_supervised!(%{id: SlowBarrier, start: {SlowBarrier, :start_link, [{name, self()}]}})

    send(name, :work)

    :ok = RunDrain.drain!(barrier: [name])

    # `work_done` is sent after the 100ms sleep; with no barrier it would not be
    # in the mailbox yet when drain! returns.
    assert_received :work_done
  end

  test "drain!/1 also stops an executor that a barrier process starts while it is flushed" do
    name = :run_drain_test_starting_barrier

    barrier =
      start_supervised!(%{
        id: StartingBarrier,
        start: {StartingBarrier, :start_link, [{name, self()}]}
      })

    # The barrier parks in `:work`: queued work that has not run when the drain starts.
    send(name, :work)
    drain = Task.async(fn -> RunDrain.drain!(barrier: [name]) end)

    Eventually.await(fn -> flush_requested?(barrier) end,
      message: "drain!/1 never flushed the barrier"
    )

    send(barrier, :release)
    assert :ok = Task.await(drain)

    # The executor did not exist when the drain began; flushing the barrier started it. Stopped
    # only before the flush, it would still be running here, to fail in the next test.
    assert_received {:executor_started, executor}
    refute Process.alive?(executor)
    assert [] = RunSupervisor.which_runs()
  end
end
