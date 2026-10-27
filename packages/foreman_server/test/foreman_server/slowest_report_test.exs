defmodule ForemanServer.SlowestReportTest do
  # The formatter CI names next to the default ones (see its moduledoc): it must report the
  # slowest tests of the NORMAL run, which `mix test --slowest` cannot (it implies --trace).
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias ForemanServer.TestSupport.SlowestReport

  @empty %{tests: [], started: %{}, modules: []}

  defp finished_test(name, time_us, opts \\ []) do
    %ExUnit.Test{
      name: name,
      module: Fake.SlowTest,
      time: time_us,
      state: Keyword.get(opts, :state),
      tags: %{file: "test/fake/slow_test.exs", line: 7, async: Keyword.get(opts, :async, false)}
    }
  end

  defp test_module(name, tests), do: %ExUnit.TestModule{name: name, tests: tests, state: nil}

  test "keeps only the 30 slowest tests, slowest first" do
    state =
      Enum.reduce(1..45, @empty, fn n, acc ->
        SlowestReport.observe_test(acc, finished_test(:"test any", n * 1_000_000))
      end)

    assert length(state.tests) == 30
    assert Enum.map(state.tests, & &1.time_us) == Enum.map(45..16//-1, &(&1 * 1_000_000))
  end

  test "the report names seconds, share of the run, module, test and location" do
    state =
      SlowestReport.observe_test(@empty, finished_test(:"test waits for a timeout", 35_265_200))

    report = SlowestReport.report(state, 100_000_000)

    assert report =~ "top 1 tests"
    assert report =~ "35.27s"
    assert report =~ "35.3%"
    assert report =~ "Fake.SlowTest waits for a timeout [test/fake/slow_test.exs:7]"
  end

  test "failed tests count, excluded, skipped and invalid ones took no time and are dropped" do
    state =
      @empty
      |> SlowestReport.observe_test(
        finished_test(:"test failed", 2_000_000, state: {:failed, []})
      )
      |> SlowestReport.observe_test(finished_test(:"test x", 9_000_000, state: {:excluded, "x"}))
      |> SlowestReport.observe_test(finished_test(:"test y", 9_000_000, state: {:skipped, "y"}))
      |> SlowestReport.observe_test(finished_test(:"test z", 9_000_000, state: {:invalid, Fake}))

    assert [%{name: "failed", time_us: 2_000_000}] = state.tests
  end

  test "an async: false module is timed from its start to its finish, an async one is not listed" do
    sync =
      test_module(Fake.SyncTest, [finished_test(:"test a", 1_000), finished_test(:"test b", 1)])

    async = test_module(Fake.AsyncTest, [finished_test(:"test c", 1_000, async: true)])

    state = %{@empty | started: %{Fake.SyncTest => 1_000, Fake.AsyncTest => 1_000}}
    state = SlowestReport.observe_module(state, sync, 13_500)
    state = SlowestReport.observe_module(state, async, 13_500)

    assert [%{module: Fake.SyncTest, time_ms: 12_500, tests: 2}] = state.modules
    assert state.started == %{}
    assert SlowestReport.report(state, 100_000_000) =~ "12.50s  12.5% Fake.SyncTest (2 tests)"
  end

  test "a module whose start was never seen is not invented" do
    state = SlowestReport.observe_module(@empty, test_module(Fake.SyncTest, []), 5_000)

    assert state.modules == []
  end

  test "an empty run has nothing to rank and a zero-length run has no percentages" do
    report = SlowestReport.report(@empty, 0)

    assert report =~ "top 0 tests"
    assert report =~ "top 0 async: false modules"

    state = SlowestReport.observe_test(@empty, finished_test(:"test a", 1))
    assert SlowestReport.report(state, 0) =~ "n/a"
  end

  test "as a formatter it folds the events of a run and prints the report at the end" do
    output =
      capture_io(fn ->
        {:ok, pid} = GenServer.start_link(SlowestReport, [])
        slow = finished_test(:"test slow", 3_000_000)
        module = test_module(Fake.SyncTest, [slow])

        GenServer.cast(pid, {:module_started, module})
        GenServer.cast(pid, {:test_finished, slow})
        GenServer.cast(pid, {:module_finished, module})
        GenServer.cast(pid, {:suite_finished, %{run: 10_000_000, async: nil, load: nil}})
        # A call after the casts returns only once the casts have been handled.
        :sys.get_state(pid)
      end)

    assert output =~ "3.00s  30.0% Fake.SlowTest slow [test/fake/slow_test.exs:7]"
    assert output =~ "Fake.SyncTest (1 tests)"
  end
end
