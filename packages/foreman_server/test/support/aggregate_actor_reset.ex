defmodule ForemanServer.TestSupport.AggregateActorReset do
  @moduledoc false
  # Aggregate actors hydrate from the event log once, when they start, and hold that state
  # for the life of the VM. The app boots before test_helper.exs empties the log, so an
  # actor the boot-time Dispatcher/BootReconciliation work started for the PREVIOUS run's
  # runs and projects keeps that run's state (`exists?: true`) after the reset, and a test
  # that registers a project with a repeating id (fixed `--seed`, `:rand`) is refused with
  # `{:already_exists, :project, id}`. Actors are started on demand, so removing them all
  # right after the log reset makes the next command rehydrate from the empty log.
  @spec reset!() :: :ok
  def reset! do
    for {id, _pid} <- live_actors() do
      _ = Supervisor.terminate_child(ForemanServer.Aggregator, id)
      _ = Supervisor.delete_child(ForemanServer.Aggregator, id)
    end

    :ok
  end

  defp live_actors do
    Registry.select(ForemanServer.AggregateRegistry, [
      {{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
  end
end
