defmodule ForemanServer.TestSupport.MeckScopeTest do
  # Mocks `ForemanServer.ProjectLimits` (small, pure, compiled to a beam so meck can keep the
  # original for passthrough). `async: false`: the mock is global.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectLimits
  alias ForemanServer.TestSupport.MeckScope

  @now ~U[2026-01-02 03:04:05Z]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:meck)
    MeckScope.new_once!(ProjectLimits)
  end

  # Each test calls `restore!/1` itself (what the `on_exit` does between tests), so the
  # assertions about "the next test" hold whatever order ExUnit runs the tests in.
  setup do
    MeckScope.restore_on_exit!(ProjectLimits)
  end

  test "delete restores the passthrough to the real function" do
    :meck.expect(ProjectLimits, :day, fn _ -> "mocked" end)
    assert ProjectLimits.day(@now) == "mocked"

    MeckScope.restore!(ProjectLimits)

    assert ProjectLimits.day(@now) == "2026-01-02"
  end

  test "expectations and call history do not leak across restore!/1" do
    :meck.expect(ProjectLimits, :day, fn _ -> "leaky" end)
    :meck.expect(ProjectLimits, :resets_at, fn _ -> :leaky end)
    assert ProjectLimits.day(@now) == "leaky"
    assert :meck.called(ProjectLimits, :day, :_)

    MeckScope.restore!(ProjectLimits)

    assert :meck.expects(ProjectLimits, true) == []
    assert :meck.num_calls(ProjectLimits, :day, :_) == 0
    assert ProjectLimits.day(@now) == "2026-01-02"
    assert ProjectLimits.resets_at(@now) == ~U[2026-01-03 00:00:00Z]
  end

  test "an expectation that raised does not break the next test" do
    :meck.expect(ProjectLimits, :day, fn _ -> raise "boom" end)
    assert_raise RuntimeError, "boom", fn -> ProjectLimits.day(@now) end
    refute :meck.validate(ProjectLimits)

    MeckScope.restore!(ProjectLimits)

    assert ProjectLimits.day(@now) == "2026-01-02"
    :meck.expect(ProjectLimits, :day, fn _ -> "fresh" end)
    assert ProjectLimits.day(@now) == "fresh"
  end
end
