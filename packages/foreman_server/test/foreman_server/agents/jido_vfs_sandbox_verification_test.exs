defmodule ForemanServer.Agents.JidoVfsSandboxVerificationTest do
  use ExUnit.Case, async: false
  @moduletag :security
  @moduletag :verification

  alias ForemanServer.Agents.VfsIsolation

  test "agent bound to worktree cannot access outside path" do
    case GenServer.whereis(VfsIsolation) do
      nil -> start_supervised!(VfsIsolation)
      _pid -> :ok
    end
    :ok = VfsIsolation.bind("agent-x", "/tmp/wt-test")

    refute VfsIsolation.allowed?("agent-x", "/etc/passwd")
    refute VfsIsolation.allowed?("agent-x", "/var/log/syslog")

    assert VfsIsolation.allowed?("agent-x", "/tmp/wt-test/file.txt")
    assert VfsIsolation.allowed?("agent-x", "/tmp/wt-test/sub/dir/file.txt")
  end

  test "unbound agent cannot access anything" do
    case GenServer.whereis(VfsIsolation) do
      nil -> start_supervised!(VfsIsolation)
      _pid -> :ok
    end
    refute VfsIsolation.allowed?("agent-unbound", "/tmp/anything")
  end
end
