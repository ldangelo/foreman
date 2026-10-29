defmodule ForemanServer.AggregatorChurnTest do
  @moduledoc """
  A restart storm among the aggregate actors stops at the `Aggregator`.

  The `Aggregator` restarts a dead actor at once (`restart: :permanent`), but only 100 times in
  5 s. Past that it gives up: it dies with every actor and the application supervisor starts it
  again, empty. The `AggregateRegistry` used to be a child of the `Aggregator` and died with it, so
  every `Registry.lookup/2` raised `unknown registry: ForemanServer.AggregateRegistry` until the
  new one was up, and each storm used up one of the few restarts the application supervisor allows
  itself (OTP's default is 3 in 5 s).

  The test kills more actors than that budget allows and asserts what must survive: the registry
  and the application supervisor (same pids), and a command to a new aggregate afterwards.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregator, CommandRouter}
  alias ForemanServer.TestSupport.Eventually

  # 120 killed actors, and the supervisor's own report for each one: nothing here asserts on them.
  @moduletag :capture_log

  # More than the Aggregator's 100 restarts in 5 s (`Aggregator.init/1`). If that budget is ever
  # raised past this number the storm no longer exhausts it, and the premise assertion below fails.
  @actors 120

  defmodule IdleAggregate do
    @moduledoc false
    # Rehydrates without touching the event store, so restarting one of its actors costs the
    # Aggregator microseconds: the storm then exhausts the restart budget on any machine, instead
    # of being spread thin by Postgres round trips.
    @behaviour ForemanServer.Aggregate

    defstruct []

    @impl true
    def initial_state, do: %__MODULE__{}

    @impl true
    def handle_command(_state, _command), do: :unhandled

    @impl true
    def apply_event(state, _event), do: state

    @impl true
    def load(_aggregate_id), do: {initial_state(), 0}
  end

  test "killing more actors than the Aggregator may restart leaves the registry and the application standing" do
    registry = Process.whereis(ForemanServer.AggregateRegistry)
    application = Process.whereis(ForemanServer.Application)
    aggregator = Process.whereis(Aggregator)

    assert is_pid(registry), "the AggregateRegistry is not running"
    assert is_pid(application), "the application supervisor is not running"
    assert is_pid(aggregator), "the Aggregator is not running"

    ids = for _ <- 1..@actors, do: "churn:#{System.unique_integer([:positive])}"
    on_exit(fn -> stop_actors(ids) end)

    killed =
      for id <- ids do
        assert {:ok, pid} = Aggregator.start_aggregate(IdleAggregate, id)
        pid
      end

    # All at once: the Aggregator then restarts them one after another, far inside 5 s.
    Enum.each(killed, &Process.exit(&1, :kill))

    # Over when the Aggregator has given up and a new one is registered. Over as well when the
    # application supervisor is gone (asserted below): no Aggregator outlives that.
    Eventually.await(
      fn ->
        Process.whereis(ForemanServer.Application) != application or
          Process.whereis(Aggregator) not in [nil, aggregator]
      end,
      timeout: 10_000,
      message:
        "the Aggregator survived #{@actors} killed actors: the storm did not exhaust its " <>
          "restart budget, so this test proves nothing; raise @actors above max_restarts"
    )

    # The application first: were it gone, the registry went with it, and blaming the Aggregator
    # for that would send the reader the wrong way.
    assert Process.whereis(ForemanServer.Application) == application,
           "the application supervisor was replaced or stopped (#{inspect(application)} -> " <>
             "#{inspect(Process.whereis(ForemanServer.Application))})"

    assert Process.alive?(application)

    assert Process.whereis(ForemanServer.AggregateRegistry) == registry,
           "the AggregateRegistry was replaced (#{inspect(registry)} -> " <>
             "#{inspect(Process.whereis(ForemanServer.AggregateRegistry))}): " <>
             "it died with the Aggregator"

    # The new Aggregator is empty and serves a command to a new aggregate through the old registry.
    project_id = "churn-#{System.unique_integer([:positive])}"
    aggregate_id = "project:#{project_id}"
    on_exit(fn -> stop_actors([aggregate_id]) end)

    assert {:ok, _event} =
             CommandRouter.dispatch(%{
               type: "project.register",
               payload: %{project_id: project_id, path: System.tmp_dir!()},
               aggregate_id: aggregate_id
             })

    assert [{actor, _}] = Registry.lookup(ForemanServer.AggregateRegistry, aggregate_id)
    assert Process.alive?(actor)
  end

  # Actors are `:permanent` children of the Aggregator: any that outlived the storm would run for
  # the rest of the VM.
  defp stop_actors(ids) do
    for id <- ids do
      _ = Supervisor.terminate_child(Aggregator, id)
      _ = Supervisor.delete_child(Aggregator, id)
    end

    :ok
  end
end
