defmodule ForemanServer.ZzCiProbeFailingLegTest do
  # THROWAWAY (foreman-r22ik): proves a failing partition turns the aggregate `foreman_server` red.
  use ExUnit.Case, async: true

  test "deliberately failing test (never merged)" do
    assert 1 == 2
  end
end
