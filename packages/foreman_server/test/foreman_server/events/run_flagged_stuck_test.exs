defmodule ForemanServer.Events.RunFlaggedStuckTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Events.RunFlaggedStuck

  test "struct/1 constructs with required keys" do
    event = %RunFlaggedStuck{run_id: "run-1", flagged_at: 1_725_000_000_000}
    assert event.run_id == "run-1"
    assert event.flagged_at == 1_725_000_000_000
  end

  test "struct!/1 raises when :flagged_at is missing" do
    assert_raise ArgumentError, fn ->
      struct!(RunFlaggedStuck, run_id: "run-2")
    end
  end

  test "struct!/1 raises when :run_id is missing" do
    assert_raise ArgumentError, fn ->
      struct!(RunFlaggedStuck, flagged_at: 1_725_000_000_000)
    end
  end

  test "Jason.encode!/1 round-trips the struct" do
    event = %RunFlaggedStuck{run_id: "run-3", flagged_at: 1_725_000_000_000}
    decoded = event |> Jason.encode!() |> Jason.decode!()
    assert decoded == %{"run_id" => "run-3", "flagged_at" => 1_725_000_000_000}
  end
end
