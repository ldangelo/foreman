defmodule ForemanServer.RunLifecycleReconcilerAppStartTest do
  @moduledoc """
  App-start wiring test for `ForemanServer.RunLifecycleReconciler`.

  Must be run with the application started (`mix test`, NOT `--no-start`).
  Running with `--no-start` will fail because the supervised reconciler is not
  present.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.RunLifecycleReconciler

  test "RunLifecycleReconciler is running under its canonical name from application supervision" do
    pid = Process.whereis(RunLifecycleReconciler)

    assert is_pid(pid),
           "RunLifecycleReconciler must be supervised and registered under its canonical name"

    assert Process.alive?(pid)

    state = :sys.get_state(pid)

    assert state.subscription in [:subscribed, :retrying]
    assert is_integer(state.interval_ms) and state.interval_ms > 0
    assert is_integer(state.timeout_ms) and state.timeout_ms > 0
  end
end
