defmodule ForemanServer.Agents.VfsIsolationTest do
  @moduledoc """
  Tests for ForemanServer.Agents.VfsIsolation.
  TRD-2026-4212be7e / JSH-T003 / TRD-034.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.VfsIsolation

  setup do
    # Start VfsIsolation GenServer for this test - it owns the ETS table.
    # The GenServer is named so subsequent tests share the same instance.
    case GenServer.whereis(ForemanServer.Agents.VfsIsolation) do
      nil -> start_supervised!(VfsIsolation)
      _pid -> :ok
    end

    # Each test gets a fresh ETS table by clearing on entry.
    # We use unique agent IDs so collisions across tests are avoided.
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

  test "bind_with_check succeeds when worktree is in allowed roots" do
    # /tmp is in the default allowed_roots for tests
    result = VfsIsolation.bind_with_check("agent-check", "/tmp/wt-allowed")
    assert :ok = result
    assert {:ok, "/tmp/wt-allowed"} = VfsIsolation.lookup("agent-check")
  end

  test "bind_with_check fails when worktree is outside allowed roots" do
    result = VfsIsolation.bind_with_check("agent-check-2", "/forbidden/path")
    assert {:error, :worktree_not_in_allowed_list} = result
    assert :not_found = VfsIsolation.lookup("agent-check-2")
  end

  test "rebind replaces existing binding" do
    :ok = VfsIsolation.bind("agent-rebind", "/tmp/wt-old")
    :ok = VfsIsolation.bind("agent-rebind", "/tmp/wt-new")
    assert {:ok, "/tmp/wt-new"} = VfsIsolation.lookup("agent-rebind")
  end
end

defmodule ForemanServer.Agents.VfsIsolationSecurityEventTest do
  @moduledoc """
  LGC-T001 / TRD-096 — security event telemetry on VFS access denial.
  Verifies that :telemetry.execute([:foreman_server, :security, :vfs_denied])
  is emitted when allowed?/2 returns false.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.VfsIsolation

  setup do
    # :telemetry must be started before we can attach handlers.
    {:ok, _} = Application.ensure_all_started(:telemetry)

    # Register a telemetry handler to capture events
    ref = make_ref()
    test_pid = self()

    handler = fn event, measurements, metadata, _config ->
      send(test_pid, {:telemetry, ref, event, measurements, metadata})
    end

    :telemetry.attach({__MODULE__, ref}, [:foreman_server, :security, :vfs_denied], handler, nil)

    on_exit(fn ->
      :telemetry.detach({__MODULE__, ref})
    end)

    {:ok, %{ref: ref}}
  end

  test "security event emitted when access outside worktree is denied", %{ref: ref} do
    worktree = Path.join(System.tmp_dir!(), "vfs-sec-#{System.unique_integer()}")
    File.mkdir_p!(worktree)

    case GenServer.whereis(VfsIsolation) do
      nil -> start_supervised!(VfsIsolation)
      _pid -> :ok
    end

    :ets.delete_all_objects(:foreman_vfs_isolation)
    :ok = VfsIsolation.bind("agent-sec", worktree)

    # Attempt access outside the worktree — should be denied
    refute VfsIsolation.allowed?("agent-sec", "/etc/passwd")

    assert_receive {:telemetry, ^ref, [:foreman_server, :security, :vfs_denied], %{count: 1},
                    %{agent_id: "agent-sec", path: "/etc/passwd", reason: :outside_worktree}}
  end

  test "security event emitted when unbound agent tries to access path", %{ref: ref} do
    case GenServer.whereis(VfsIsolation) do
      nil -> start_supervised!(VfsIsolation)
      _pid -> :ok
    end

    :ets.delete_all_objects(:foreman_vfs_isolation)

    # No binding — any path is denied
    refute VfsIsolation.allowed?("agent-unbound-sec", "/tmp/somewhere")

    assert_receive {:telemetry, ^ref, [:foreman_server, :security, :vfs_denied], %{count: 1},
                    %{agent_id: "agent-unbound-sec", path: "/tmp/somewhere", reason: :no_binding}}
  end

  test "no security event emitted when access is allowed", %{ref: ref} do
    worktree = Path.join(System.tmp_dir!(), "vfs-ok-#{System.unique_integer()}")
    File.mkdir_p!(worktree)

    case GenServer.whereis(VfsIsolation) do
      nil -> start_supervised!(VfsIsolation)
      _pid -> :ok
    end

    :ets.delete_all_objects(:foreman_vfs_isolation)
    :ok = VfsIsolation.bind("agent-ok", worktree)

    # Access within worktree — should be allowed
    assert VfsIsolation.allowed?("agent-ok", Path.join(worktree, "file.txt"))

    # No denial event should be sent
    refute_received {:telemetry, ^ref, [:foreman_server, :security, :vfs_denied], _, _}
  end
end
