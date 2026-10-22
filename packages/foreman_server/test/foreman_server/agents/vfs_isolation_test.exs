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
    assert {:ok, [VfsIsolation.canonical_path("/tmp/wt-a")]} == VfsIsolation.lookup("agent-1")
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
    assert {:ok, [VfsIsolation.canonical_path("/tmp/wt-d")]} == VfsIsolation.lookup("agent-4")
    :ok = VfsIsolation.unbind("agent-4")
    assert :not_found = VfsIsolation.lookup("agent-4")
  end

  test "bind_with_check succeeds when worktree is in allowed roots" do
    # /tmp is in the default allowed_roots for tests
    result = VfsIsolation.bind_with_check("agent-check", "/tmp/wt-allowed")
    assert :ok = result

    assert {:ok, [VfsIsolation.canonical_path("/tmp/wt-allowed")]} ==
             VfsIsolation.lookup("agent-check")
  end

  test "bind_with_check fails when worktree is outside allowed roots" do
    result = VfsIsolation.bind_with_check("agent-check-2", "/forbidden/path")
    assert {:error, :worktree_not_in_allowed_list} = result
    assert :not_found = VfsIsolation.lookup("agent-check-2")
  end

  test "rebind replaces existing binding" do
    :ok = VfsIsolation.bind("agent-rebind", "/tmp/wt-old")
    :ok = VfsIsolation.bind("agent-rebind", "/tmp/wt-new")

    assert {:ok, [VfsIsolation.canonical_path("/tmp/wt-new")]} ==
             VfsIsolation.lookup("agent-rebind")
  end

  describe "multiple roots and canonicalisation" do
    setup do
      base = Path.join(System.tmp_dir!(), "vfs-multi-#{System.unique_integer([:positive])}")
      a = Path.join(base, "a")
      b = Path.join(base, "b")
      outside = Path.join(base, "outside")
      for dir <- [a, b, outside], do: File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(base) end)
      {:ok, base: base, a: a, b: b, outside: outside}
    end

    test "a single path is accepted as [path]; lookup returns the canonical roots", %{a: a, b: b} do
      :ok = VfsIsolation.bind("multi-1", a)
      assert {:ok, [VfsIsolation.canonical_path(a)]} == VfsIsolation.lookup("multi-1")

      :ok = VfsIsolation.bind("multi-1", [a, b])

      assert {:ok, [VfsIsolation.canonical_path(a), VfsIsolation.canonical_path(b)]} ==
               VfsIsolation.lookup("multi-1")
    end

    test "any bound root allows; others deny", %{a: a, b: b, outside: outside} do
      :ok = VfsIsolation.bind("multi-2", [a, b])
      assert VfsIsolation.allowed?("multi-2", Path.join(a, "x.txt"))
      assert VfsIsolation.allowed?("multi-2", Path.join(b, "sub/y.txt"))
      assert VfsIsolation.allowed?("multi-2", b)
      refute VfsIsolation.allowed?("multi-2", Path.join(outside, "z.txt"))
    end

    test "the boundary is a path separator, not a string prefix", %{a: a, base: base} do
      sibling = a <> "-evil"
      File.mkdir_p!(sibling)
      assert Path.dirname(sibling) == base
      :ok = VfsIsolation.bind("multi-3", [a])
      refute VfsIsolation.allowed?("multi-3", Path.join(sibling, "f.txt"))
      refute VfsIsolation.allowed?("multi-3", sibling)
    end

    test "'..' traversal out of a root is denied", %{a: a, outside: outside} do
      :ok = VfsIsolation.bind("multi-4", [a])
      refute VfsIsolation.allowed?("multi-4", Path.join([a, "..", "outside", "z.txt"]))
      assert VfsIsolation.allowed?("multi-4", Path.join([a, "sub", "..", "ok.txt"]))
      assert File.dir?(outside)
    end

    test "a symlink inside a root pointing outside is denied", %{a: a, outside: outside} do
      File.ln_s!(outside, Path.join(a, "escape"))
      :ok = VfsIsolation.bind("multi-5", [a])
      refute VfsIsolation.allowed?("multi-5", Path.join([a, "escape", "z.txt"]))
      refute VfsIsolation.allowed?("multi-5", Path.join(a, "escape"))
    end

    test "a symlinked root is bound as its target", %{base: base, b: b} do
      link = Path.join(base, "link-to-b")
      File.ln_s!(b, link)
      :ok = VfsIsolation.bind("multi-6", [link])
      assert VfsIsolation.allowed?("multi-6", Path.join(b, "f.txt"))
      assert VfsIsolation.allowed?("multi-6", Path.join(link, "f.txt"))
    end

    test "a non-existent final component is normalised, not rejected", %{a: a} do
      :ok = VfsIsolation.bind("multi-7", [a])
      assert VfsIsolation.allowed?("multi-7", Path.join(a, "not/yet/created.txt"))
    end

    test "bind_with_check checks every root" do
      ok_root = "/tmp/wt-multi-ok"

      assert {:error, :worktree_not_in_allowed_list} =
               VfsIsolation.bind_with_check("multi-8", [ok_root, "/forbidden/path"])

      assert :not_found = VfsIsolation.lookup("multi-8")
      assert :ok = VfsIsolation.bind_with_check("multi-8", [ok_root])
    end

    test "the allowlist is matched on canonical paths with a boundary" do
      # `/tmp` is allowed; `/tmpevil` shares the string prefix but not the directory.
      assert {:error, :worktree_not_in_allowed_list} = VfsIsolation.allowlist_check("/tmpevil/wt")
      assert {:error, :worktree_not_in_allowed_list} = VfsIsolation.allowlist_check("/tmp/../etc")
      assert :ok = VfsIsolation.allowlist_check("/tmp/wt-x/../wt-y")
    end
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
