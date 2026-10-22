defmodule ForemanServer.RunDrainTest do
  @moduledoc """
  The store/run-slot resets must not leave a previous test's run machinery
  running (see `ForemanServer.TestSupport.RunDrain`): a leftover executor that
  finishes after the reset hits `:project_not_found`, races the
  `run_slots:global` actor kill, and emits terminal events about tasks the
  freshly reset store has never seen.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.TestSupport.{ProjectionStoreReset, RunDrain, RunSlotsReset}
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
end
