defmodule ForemanServer.AC1AggregateActorTest do
  use ExUnit.Case, async: false

  # AC1: Aggregate actor starts on first dispatch, :temporary restart, lazy reopen.
  # Confirmed from Commanded 1.4.10 source: aggregate.ex uses `use GenServer, restart: :temporary`

  setup do
    case ForemanServer.Application.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
    :ok
  end

  defp aggregate_name(run_id) do
    {ForemanServer.Application, ForemanServer.AC1RunAggregate, run_id}
  end

  defp aggregate_pid(run_id) do
    [{pid, _}] = Registry.lookup(ForemanServer.Application.LocalRegistry, aggregate_name(run_id))
    pid
  end

  test "AC1: aggregate starts on first dispatch and handles command" do
    run_id = Commanded.UUID.uuid4()
    task_id = Commanded.UUID.uuid4()

    :ok = ForemanServer.Application.dispatch(%ForemanServer.Commands.StartRun{
      run_id: run_id,
      task_id: task_id
    })

    # Aggregate should be alive and have processed the command
    %{status: :running, run_id: ^run_id, task_id: ^task_id} =
      Commanded.Aggregates.Aggregate.aggregate_state(
        ForemanServer.Application,
        ForemanServer.AC1RunAggregate,
        run_id
      )
  end

  test "AC1: aggregate :temporary restart — process exits on crash, reopens lazily on next dispatch" do
    run_id = Commanded.UUID.uuid4()
    task_id = Commanded.UUID.uuid4()

    # Start aggregate via first dispatch
    :ok = ForemanServer.Application.dispatch(%ForemanServer.Commands.StartRun{
      run_id: run_id,
      task_id: task_id
    })

    pid = aggregate_pid(run_id)
    assert Process.alive?(pid)

    # Simulate crash
    Process.exit(pid, :kill)
    Process.sleep(50)

    # No aggregate process should be running (temporary restart = no auto-restart)
    assert Registry.lookup(ForemanServer.Application.LocalRegistry, aggregate_name(run_id)) == []

    # Dispatch again — aggregate reopens lazily
    :ok = ForemanServer.Application.dispatch(%ForemanServer.Commands.StartRun{
      run_id: run_id,
      task_id: task_id
    })

    new_pid = aggregate_pid(run_id)
    assert Process.alive?(new_pid)
  end
end
