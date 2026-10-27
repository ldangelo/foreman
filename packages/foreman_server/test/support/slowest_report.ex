defmodule ForemanServer.TestSupport.SlowestReport do
  @moduledoc """
  Prints the slowest tests and the slowest `async: false` modules of a run, as an ExUnit formatter.

  `mix test --slowest N` is not usable for this: it implies `--trace`, which runs every module one
  at a time (`max_cases: 1`) and switches test timeouts off, so its numbers describe a different
  run from the one CI executes. This formatter only watches the normal concurrent run.

    * a test's time is `ExUnit.Test.time/0`: the test body plus its own `setup`;
    * a module's time is the wall clock between its start and finish events, so it also covers
      `setup_all` and `on_exit`; it is only meaningful for `async: false` modules, because
      concurrent modules overlap each other, and only those are listed.

  Name it next to the default formatters, it adds up with them:

      mix test --formatter ForemanServer.TestSupport.SlowestReport

  CI does that, so a log names the next slow test before the suite has doubled in length again.
  """

  use GenServer

  @tests 30
  @modules 15

  @type test_row :: %{
          time_us: non_neg_integer(),
          module: module(),
          name: String.t(),
          file: String.t(),
          line: non_neg_integer()
        }
  @type module_row :: %{time_ms: non_neg_integer(), module: module(), tests: non_neg_integer()}
  @type state :: %{
          tests: [test_row()],
          started: %{optional(module()) => integer()},
          modules: [module_row()]
        }

  @impl true
  def init(_opts), do: {:ok, %{tests: [], started: %{}, modules: []}}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    {:noreply, observe_test(state, test)}
  end

  def handle_cast({:module_started, %ExUnit.TestModule{name: name}}, state) do
    {:noreply, put_in(state.started[name], System.monotonic_time(:millisecond))}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{} = test_module}, state) do
    {:noreply, observe_module(state, test_module, System.monotonic_time(:millisecond))}
  end

  def handle_cast({:suite_finished, times_us}, state) do
    IO.puts(report(state, Map.get(times_us, :run, 0)))
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc "Folds one finished test in; excluded, skipped and invalid tests took no time and are dropped."
  @spec observe_test(state(), ExUnit.Test.t()) :: state()
  def observe_test(state, %ExUnit.Test{state: test_state} = test)
      when is_nil(test_state) or elem(test_state, 0) == :failed do
    row = %{
      time_us: test.time,
      module: test.module,
      name: test_name(test.name),
      file: relative(test.tags[:file]),
      line: test.tags[:line] || 0
    }

    %{state | tests: keep_slowest([row | state.tests], @tests, & &1.time_us)}
  end

  def observe_test(state, %ExUnit.Test{}), do: state

  @doc "Folds one finished module in (`now_ms` is the monotonic clock when it finished)."
  @spec observe_module(state(), ExUnit.TestModule.t(), integer()) :: state()
  def observe_module(state, %ExUnit.TestModule{name: name, tests: tests}, now_ms) do
    {started_ms, started} = Map.pop(state.started, name)
    state = %{state | started: started}

    if is_integer(started_ms) and not Enum.any?(tests, &(&1.tags[:async] == true)) do
      row = %{time_ms: now_ms - started_ms, module: name, tests: length(tests)}
      %{state | modules: keep_slowest([row | state.modules], @modules, & &1.time_ms)}
    else
      state
    end
  end

  @doc "The report printed at the end of the suite; `run_us` is the suite's wall time."
  @spec report(state(), non_neg_integer()) :: String.t()
  def report(%{tests: tests, modules: modules}, run_us) do
    Enum.join(
      [
        "\nSlowestReport: top #{length(tests)} tests (seconds; each test's own setup included)"
        | Enum.map(tests, &test_line(&1, run_us))
      ] ++
        [
          "\nSlowestReport: top #{length(modules)} async: false modules " <>
            "(seconds of wall clock, setup_all and on_exit included)"
          | Enum.map(modules, &module_line(&1, run_us))
        ],
      "\n"
    )
  end

  defp test_line(row, run_us) do
    "#{seconds(row.time_us)}s #{percent(row.time_us, run_us)} #{inspect(row.module)} " <>
      "#{row.name} [#{row.file}:#{row.line}]"
  end

  defp module_line(row, run_us) do
    "#{seconds(row.time_ms * 1000)}s #{percent(row.time_ms * 1000, run_us)} " <>
      "#{inspect(row.module)} (#{row.tests} tests)"
  end

  defp keep_slowest(rows, limit, key), do: rows |> Enum.sort_by(key, :desc) |> Enum.take(limit)

  defp seconds(us),
    do: String.pad_leading(:erlang.float_to_binary(us / 1_000_000, decimals: 2), 8)

  defp percent(_us, 0), do: String.pad_leading("n/a", 6)

  defp percent(us, run_us) do
    String.pad_leading(:erlang.float_to_binary(us / run_us * 100, decimals: 1) <> "%", 6)
  end

  defp test_name(name), do: name |> Atom.to_string() |> String.replace_prefix("test ", "")

  defp relative(nil), do: "?"
  defp relative(file), do: Path.relative_to_cwd(file)
end
