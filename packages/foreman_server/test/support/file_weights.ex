defmodule ForemanServer.TestSupport.FileWeights do
  @moduledoc """
  Writes how long each test file takes, as an ExUnit formatter, so `scripts/ci/test-weights.txt`
  (the input of `scripts/ci/partition-tests.sh`, which balances the CI legs) can be regenerated
  from a real run:

      FOREMAN_TEST_WEIGHTS_OUT=/tmp/weights.txt \\
        mix test --formatter ForemanServer.TestSupport.FileWeights
      sort /tmp/weights.txt > scripts/ci/test-weights.txt

  Output is one `path weight_ms` line per file (path relative to the package, like the paths
  `mix test` takes). The weight is the sum of the file's test times (`ExUnit.Test.time/0`: body
  plus the test's own `setup`) in milliseconds, at least 1. `async: false` files run one after
  another, so their sum is what a leg waits for; an `async: true` file overlaps the others, so
  it counts a quarter of its sum.

  Without `FOREMAN_TEST_WEIGHTS_OUT` the formatter does nothing. Time spent in `setup_all` and
  `on_exit` is not attributed to a test, so a file that is slow only there weighs less than it
  costs: run the regeneration on a quiet machine and sanity check the legs on a real CI run.
  """

  use GenServer

  @async_divisor 4

  @type state :: %{optional(String.t()) => %{us: non_neg_integer(), async?: boolean()}}

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, state) do
    {:noreply, observe_test(state, test)}
  end

  def handle_cast({:suite_finished, _times_us}, state) do
    case System.get_env("FOREMAN_TEST_WEIGHTS_OUT") do
      path when is_binary(path) and path != "" -> File.write!(path, render(state))
      _unset -> :ok
    end

    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc "Adds one finished test to its file's total; excluded, skipped and invalid tests are dropped."
  @spec observe_test(state(), ExUnit.Test.t()) :: state()
  def observe_test(state, %ExUnit.Test{state: test_state} = test)
      when is_nil(test_state) or elem(test_state, 0) == :failed do
    file = Path.relative_to_cwd(test.tags[:file])
    async? = test.tags[:async] == true

    Map.update(state, file, %{us: test.time, async?: async?}, fn row ->
      %{row | us: row.us + test.time}
    end)
  end

  def observe_test(state, %ExUnit.Test{}), do: state

  @doc "The `path weight_ms` lines, sorted by path."
  @spec render(state()) :: String.t()
  def render(state) do
    state
    |> Enum.sort()
    |> Enum.map_join(fn {file, row} -> "#{file} #{weight_ms(row)}\n" end)
  end

  defp weight_ms(%{us: us, async?: true}), do: max(div(us, 1000 * @async_divisor), 1)
  defp weight_ms(%{us: us, async?: false}), do: max(div(us, 1000), 1)
end
