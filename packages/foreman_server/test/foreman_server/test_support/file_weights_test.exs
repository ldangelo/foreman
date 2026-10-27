defmodule ForemanServer.TestSupport.FileWeightsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TestSupport.FileWeights

  defp test_in(file, time_us, opts \\ []) do
    %ExUnit.Test{
      name: :"test x",
      module: __MODULE__,
      time: time_us,
      state: Keyword.get(opts, :state),
      tags: %{file: Path.expand(file), async: Keyword.get(opts, :async, false)}
    }
  end

  test "sums the tests of a file; async files count a quarter, every file at least 1 ms" do
    state =
      %{}
      |> FileWeights.observe_test(test_in("test/a_test.exs", 1_500_000))
      |> FileWeights.observe_test(test_in("test/a_test.exs", 500_000))
      |> FileWeights.observe_test(test_in("test/b_test.exs", 800_000, async: true))
      |> FileWeights.observe_test(test_in("test/c_test.exs", 10))

    assert FileWeights.render(state) ==
             "test/a_test.exs 2000\ntest/b_test.exs 200\ntest/c_test.exs 1\n"
  end

  test "skipped and excluded tests take no time and add no file" do
    state =
      FileWeights.observe_test(%{}, test_in("test/a_test.exs", 5, state: {:skipped, "no"}))

    assert state == %{}
    assert FileWeights.render(state) == ""
  end

  test "a failed test still counts: the leg waited for it" do
    state =
      FileWeights.observe_test(
        %{},
        test_in("test/a_test.exs", 3_000_000, state: {:failed, []})
      )

    assert FileWeights.render(state) == "test/a_test.exs 3000\n"
  end
end
