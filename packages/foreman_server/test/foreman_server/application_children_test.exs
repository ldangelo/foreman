defmodule ForemanServer.ApplicationChildrenTest do
  @moduledoc """
  The application's supervision list: which children a configuration boots, and in what order.

  `PrWatcher`, `PrMonitor` and `Schedule.Ticker` were once fully implemented, unit-tested with
  `start_supervised!`, and listed in no child spec, so no server could ever run them. The test
  environment switches all three off, which is why nothing noticed. These tests read the list
  `ForemanServer.Application.start/2` itself supervises (`Application.children/0`) under each
  switch, so dropping a `maybe_*` call from it, reordering it, or flipping a default fails here.

  What is NOT proven here: that GitHub talks to a booted watcher. The watcher's own behaviour is
  `pr_watcher_test.exs`; this file proves it is wired in.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{
    AggregateRegistry,
    Aggregator,
    CommandRouter,
    EventStore,
    PrMonitor,
    PrWatcher,
    ProjectionStore
  }

  alias ForemanServer.Aggregates.BeadsDbLease.{KeeperRegistry, KeeperSupervisor}
  alias ForemanServer.Schedule.Ticker
  alias ForemanServer.TaskProviders.{BeadsOrphanJanitorSupervisor, BeadsWatcherSupervisor}
  alias ForemanServer.Workflow.{BootReconciliation, Dispatcher, RunSupervisor}

  @config_dir Path.expand("../../config", __DIR__)

  # Every key a test below writes; restored after each test, deleting a key that was unset.
  @app_env_keys [:pr_watcher, :pr_monitor_enabled, :schedule]

  # The operator switches `config/runtime.exs` reads. Cleared before a config is evaluated so a
  # developer's shell cannot change a test's outcome.
  @switches ~w(FOREMAN_PR_WATCHER_ENABLED FOREMAN_PR_MONITOR_ENABLED FOREMAN_SCHEDULE_TICKER_ENABLED)

  setup do
    originals =
      for key <- @app_env_keys, into: %{}, do: {key, Application.fetch_env(:foreman_server, key)}

    on_exit(fn ->
      for {key, original} <- originals do
        case original do
          {:ok, value} -> Application.put_env(:foreman_server, key, value)
          :error -> Application.delete_env(:foreman_server, key)
        end
      end
    end)
  end

  # Ids in start order, as the supervisor will see them (`Supervisor.child_spec/2` is what
  # `Supervisor.start_link/2` applies to every entry).
  defp child_ids do
    Enum.map(ForemanServer.Application.children(), fn child ->
      child |> Supervisor.child_spec([]) |> Map.fetch!(:id)
    end)
  end

  defp watcher(on?), do: Application.put_env(:foreman_server, :pr_watcher, enabled: on?)
  defp monitor(on?), do: Application.put_env(:foreman_server, :pr_monitor_enabled, on?)

  defp ticker(on?) do
    schedule = Application.get_env(:foreman_server, :schedule, [])
    Application.put_env(:foreman_server, :schedule, Keyword.put(schedule, :ticker_enabled, on?))
  end

  # The ids the list holds with the three switches set as given.
  defp list_with(watcher: watcher, monitor: monitor, ticker: ticker) do
    watcher(watcher)
    monitor(monitor)
    ticker(ticker)
    child_ids()
  end

  defp index_of(ids, id), do: Enum.find_index(ids, &(&1 == id))

  # `id` is supervised, and later than every id in `dependencies`: the pollers and subscribers
  # read projections and dispatch commands from their first message.
  defp assert_started_after(ids, id, dependencies) do
    assert index = index_of(ids, id), "#{inspect(id)} is not in the child list"

    for dependency <- dependencies do
      assert dependency_index = index_of(ids, dependency),
             "#{inspect(dependency)} is not in the child list"

      assert dependency_index < index,
             "#{inspect(id)} (at #{index}) must start after #{inspect(dependency)} " <>
               "(at #{dependency_index})"
    end
  end

  describe "PrWatcher" do
    test "is supervised, after the ProjectionStore and CommandRouter it uses, while enabled" do
      watcher(true)

      assert_started_after(child_ids(), PrWatcher, [ProjectionStore, CommandRouter])
    end

    test "is not supervised once it is disabled" do
      watcher(false)

      refute PrWatcher in child_ids()
    end
  end

  describe "PrMonitor" do
    test "is supervised, after the ProjectionStore and CommandRouter it uses, while polling is on" do
      monitor(true)

      assert_started_after(child_ids(), PrMonitor, [ProjectionStore, CommandRouter])
    end

    test "is not supervised while polling is off" do
      monitor(false)

      refute PrMonitor in child_ids()
    end
  end

  describe "Schedule.Ticker" do
    test "is supervised, after the ProjectionStore and CommandRouter it uses, while enabled" do
      ticker(true)

      assert_started_after(child_ids(), Ticker, [ProjectionStore, CommandRouter])
    end

    test "is not supervised once it is disabled" do
      ticker(false)

      refute Ticker in child_ids()
    end
  end

  describe "BeadsDbLease.KeeperSupervisor" do
    test "is supervised after the Aggregator it dispatches through and before every lease caller" do
      # Restored after the test; the test environment leaves the first two off.
      for key <- [
            :start_beads_watcher?,
            :start_beads_orphan_janitor?,
            :start_boot_reconciliation?
          ] do
        ForemanServer.TestSupport.Eventually.put_env_for_test(:foreman_server, key, true)
      end

      ids = child_ids()

      # The keepers register under a stable id in the KeeperRegistry the moment they start, so
      # the registry is up before the first keeper can be asked for.
      assert_started_after(ids, KeeperRegistry, [EventStore, Aggregator])
      assert_started_after(ids, KeeperSupervisor, [EventStore, Aggregator, KeeperRegistry])

      # No lease command can append before the CommandRouter runs, so no `with_lease/4` call can
      # reach a lease before it either; the callers below start no earlier than that.
      callers = [
        CommandRouter,
        BeadsWatcherSupervisor,
        BeadsOrphanJanitorSupervisor,
        BootReconciliation,
        RunSupervisor,
        Dispatcher
      ]

      for caller <- callers do
        assert_started_after(ids, caller, [KeeperSupervisor])
      end
    end
  end

  describe "AggregateRegistry" do
    test "is the application's own child, started before the Aggregator whose actors register in it" do
      ids = child_ids()

      # Not a child of the Aggregator: a restart storm that exhausts the Aggregator's budget takes
      # it down with every actor, and a registry inside it went down too (aggregator_churn_test.exs
      # proves the registry survives that).
      assert AggregateRegistry in ids
      assert_started_after(ids, Aggregator, [AggregateRegistry])
    end
  end

  describe "the application supervisor" do
    test "tolerates 50 restarts in 10 s, not OTP's default of 3 in 5 s" do
      # What `start/2` hands to `Supervisor.start_link/2`. The running supervisor's intensity has
      # no public reader (`:sys.get_state/1` returns its internal state record, which OTP neither
      # documents nor promises to keep), so the options are pinned where they are defined;
      # `start/2` takes them from here.
      assert ForemanServer.Application.supervisor_opts() == [
               strategy: :one_for_one,
               name: ForemanServer.Application,
               max_restarts: 50,
               max_seconds: 10
             ]
    end
  end

  test "each switch moves only its own child" do
    all_off = list_with(watcher: false, monitor: false, ticker: false)
    all_on = list_with(watcher: true, monitor: true, ticker: true)

    # Exactly these three differ, and the list keeps them in this order.
    assert all_on -- all_off == [PrWatcher, PrMonitor, Ticker]
    assert all_off -- all_on == []

    assert Enum.filter(all_on, &(&1 in [PrWatcher, PrMonitor, Ticker])) ==
             [PrWatcher, PrMonitor, Ticker]

    assert list_with(watcher: true, monitor: false, ticker: false) -- all_off == [PrWatcher]
    assert list_with(watcher: false, monitor: true, ticker: false) -- all_off == [PrMonitor]
    assert list_with(watcher: false, monitor: false, ticker: true) -- all_off == [Ticker]
  end

  test "with every optional child enabled the supervisor accepts the list: ids are unique" do
    watcher(true)
    monitor(true)
    ticker(true)

    ids = child_ids()

    # `Supervisor.start_link/2` refuses a duplicate id, which no test ever sees while these
    # three are off: a boot with all of them on would be the first time.
    assert ids == Enum.uniq(ids)
  end

  test "the running application supervises the children the list names" do
    live = ForemanServer.Application |> Supervisor.which_children() |> Enum.map(&elem(&1, 0))

    missing = child_ids() -- live

    assert missing == [],
           "start/2 does not supervise #{inspect(missing)}, which children/0 lists"
  end

  describe "the production child specs, started as listed" do
    test "the watcher boots with its default options and answers" do
      watcher(true)
      assert PrWatcher in child_ids()
      refute PrWatcher.running?()

      # The spec `children/0` holds, not one with test options: `init/1` subscribes to the
      # ProjectionStore (a failed subscribe would stop it) and starts its task supervisor.
      start_supervised!(Enum.find(ForemanServer.Application.children(), &(&1 == PrWatcher)))

      assert PrWatcher.running?()
      assert %{observations: 0, errors: 0, last_error: nil} = PrWatcher.stats()

      unowned =
        "https://github.com/acme/never-associated-#{System.unique_integer([:positive])}/pull/1"

      assert {:error, :not_watched} = PrWatcher.refresh_now(unowned)
    end

    test "the monitor boots with its default options and answers" do
      monitor(true)
      refute Process.whereis(PrMonitor)

      start_supervised!(Enum.find(ForemanServer.Application.children(), &(&1 == PrMonitor)))

      assert is_pid(Process.whereis(PrMonitor))
      assert %{last_count: 0, last_errors: 0} = PrMonitor.stats()
    end
  end

  describe "the stock production configuration" do
    test "boots the PR watcher and the ticker, and leaves polling to an opt-in" do
      ids = boot_ids_with_production_config(%{})

      assert PrWatcher in ids
      assert Ticker in ids
      refute PrMonitor in ids

      assert_started_after(ids, PrWatcher, [ProjectionStore, CommandRouter])
      assert_started_after(ids, Ticker, [ProjectionStore, CommandRouter])
      assert ids == Enum.uniq(ids)
    end

    test "FOREMAN_PR_WATCHER_ENABLED=false stops the watcher; no other value does" do
      refute PrWatcher in boot_ids_with_production_config(%{
               "FOREMAN_PR_WATCHER_ENABLED" => "false"
             })

      for other <- ["true", "0", "FALSE", ""] do
        assert PrWatcher in boot_ids_with_production_config(%{
                 "FOREMAN_PR_WATCHER_ENABLED" => other
               }),
               "#{inspect(other)} must leave the watcher on"
      end
    end

    test "FOREMAN_PR_MONITOR_ENABLED=true starts the poller; only the exact string does" do
      ids = boot_ids_with_production_config(%{"FOREMAN_PR_MONITOR_ENABLED" => "true"})

      assert_started_after(ids, PrMonitor, [ProjectionStore, CommandRouter])

      for other <- ["false", "1", "TRUE", ""] do
        refute PrMonitor in boot_ids_with_production_config(%{
                 "FOREMAN_PR_MONITOR_ENABLED" => other
               }),
               "#{inspect(other)} must leave polling off"
      end
    end

    test "FOREMAN_SCHEDULE_TICKER_ENABLED=false stops the ticker, true keeps it, junk refuses to boot" do
      refute Ticker in boot_ids_with_production_config(%{
               "FOREMAN_SCHEDULE_TICKER_ENABLED" => "false"
             })

      assert Ticker in boot_ids_with_production_config(%{
               "FOREMAN_SCHEDULE_TICKER_ENABLED" => "true"
             })

      error =
        assert_raise RuntimeError, fn ->
          boot_ids_with_production_config(%{"FOREMAN_SCHEDULE_TICKER_ENABLED" => "yes"})
        end

      assert error.message ==
               ~s(FOREMAN_SCHEDULE_TICKER_ENABLED must be "true" or "false", got: "yes")
    end
  end

  # What a release applies at boot: `config/config.exs` (which imports `prod.exs`) merged with
  # `config/runtime.exs`, evaluated for `:prod` with the given operator switches in the OS
  # environment. Only the keys the three children read are copied into the application
  # environment (an unset one is deleted, exactly as a prod config leaves it), and the child list
  # is read back through the same `children/0` `start/2` uses.
  defp boot_ids_with_production_config(env_vars) do
    config =
      with_os_env(Map.merge(Map.new(@switches, &{&1, nil}), env_vars), fn ->
        base = Config.Reader.read!(Path.join(@config_dir, "config.exs"), env: :prod)
        runtime = Config.Reader.read!(Path.join(@config_dir, "runtime.exs"), env: :prod)

        base |> Config.Reader.merge(runtime) |> Keyword.fetch!(:foreman_server)
      end)

    for key <- @app_env_keys do
      case Keyword.fetch(config, key) do
        {:ok, value} -> Application.put_env(:foreman_server, key, value)
        :error -> Application.delete_env(:foreman_server, key)
      end
    end

    child_ids()
  end

  defp with_os_env(vars, fun) do
    originals = Map.new(vars, fn {name, _value} -> {name, System.get_env(name)} end)

    try do
      Enum.each(vars, fn {name, value} -> put_os_env(name, value) end)
      fun.()
    after
      Enum.each(originals, fn {name, value} -> put_os_env(name, value) end)
    end
  end

  defp put_os_env(name, nil), do: System.delete_env(name)
  defp put_os_env(name, value), do: System.put_env(name, value)
end
