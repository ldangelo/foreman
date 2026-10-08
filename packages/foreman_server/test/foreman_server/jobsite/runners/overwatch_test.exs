defmodule ForemanServer.Jobsite.Runners.OverwatchTest do
  # The runner's outcome mapping on the script path: a deadline that elapses
  # while the launch process is still alive reports `:agent_idle_timeout`,
  # carrying the executor's original reason (`:worker_timeout`) in
  # `details.reason`. The wait itself (`wait_for_worker_result/4`, the DOWN
  # race, mailbox draining, the dead-at-deadline branch) is pinned
  # deterministically in `run_executor_test.exs`, which exercises it through
  # `Runners.Overwatch.__wait_for_worker_result_for_test__/4`.
  use ExUnit.Case, async: false

  alias ForemanServer.Jobsite.{Agent, Error, Runners}

  defmodule HangingWorkerAdapter do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_info({:overwatch_activate, _worker_id, _run_id, parent}, state) do
      send(parent, {:overwatch_activated, self()})
      # Deliberately never sends {:worker_result, _} — stays alive so the
      # runner's timeout branch must hit the `Process.alive?/1 == true` arm.
      {:noreply, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  setup do
    previous = Application.get_env(:foreman_server, :worker_adapter)
    Application.put_env(:foreman_server, :worker_adapter, HangingWorkerAdapter)
    start_supervised!({ForemanServer.Overwatch, []}, id: :overwatch)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:foreman_server, :worker_adapter)
        adapter -> Application.put_env(:foreman_server, :worker_adapter, adapter)
      end
    end)

    :ok
  end

  test "reports :agent_idle_timeout (not :agent_failed) when the worker is still alive at the deadline" do
    run_id = "run-overwatch-timeout-#{System.unique_integer([:positive])}"
    agent = %Agent{provider: :claude, model: "test-model"}

    assert {:error, %Error{code: :agent_idle_timeout} = error} =
             Runners.Overwatch.run(agent, "do the thing", nil,
               run_id: run_id,
               idle_timeout_ms: 50
             )

    assert error.details.timeout_ms == 50
  end
end
