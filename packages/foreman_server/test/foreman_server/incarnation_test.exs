defmodule ForemanServer.IncarnationTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Incarnation

  test "id/0 is one non-empty string for the life of the VM, whichever process asks" do
    id = Incarnation.id()

    assert is_binary(id) and id != ""
    assert Incarnation.id() == id

    tasks = for _ <- 1..8, do: Task.async(&Incarnation.id/0)
    assert Enum.all?(tasks, &(Task.await(&1) == id))
  end

  test "started_at_ms/0 is one monotonic reading, fixed at creation, before any later reading" do
    started = Incarnation.started_at_ms()

    assert is_integer(started)
    assert Incarnation.started_at_ms() == started
    assert started <= System.monotonic_time(:millisecond)

    tasks = for _ <- 1..8, do: Task.async(&Incarnation.started_at_ms/0)
    assert Enum.all?(tasks, &(Task.await(&1) == started))
  end
end
