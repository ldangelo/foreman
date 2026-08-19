defmodule ForemanServer.Agents.VfsIsolationTest do
  @moduledoc """
  Tests for ForemanServer.Agents.VfsIsolation.
  TRD-2026-4212be7e / JSH-T003 / TRD-034.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.VfsIsolation

  setup do
    # Each test gets a fresh ETS table by clearing on entry. The GenServer
    # is shared via the named process, but we use unique agent IDs so
    # collisions across tests are avoided.
    :ets.delete_all_objects(:foreman_vfs_isolation)
    :ok
  end

  test "bind and lookup returns bound path" do
    :ok = VfsIsolation.bind("agent-1", "/tmp/wt-a")
    assert {:ok, "/tmp/wt-a"} = VfsIsolation.lookup("agent-1")
  end

  test "lookup returns :not_found for unbound agent" do
    assert :not_found = VfsIsolation.lookup("unknown-agent")
  end

  test "allowed? path inside worktree returns true" do
    :ok = VfsIsolation.bind("agent-2", "/tmp/wt-b")
    assert VfsIsolation.allowed?("agent-2", "/tmp/wt-b/sub/file.txt")
  end

  test "allowed? path outside worktree returns false" do
    :ok = VfsIsolation.bind("agent-3", "/tmp/wt-c")
    refute VfsIsolation.allowed?("agent-3", "/etc/passwd")
  end

  test "allowed? returns false for unbound agent" do
    refute VfsIsolation.allowed?("never-bound", "/tmp/whatever")
  end

  test "unbind removes the binding" do
    :ok = VfsIsolation.bind("agent-4", "/tmp/wt-d")
    assert {:ok, "/tmp/wt-d"} = VfsIsolation.lookup("agent-4")
    :ok = VfsIsolation.unbind("agent-4")
    assert :not_found = VfsIsolation.lookup("agent-4")
  end
end