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
end
