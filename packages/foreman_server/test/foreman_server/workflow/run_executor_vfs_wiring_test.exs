defmodule ForemanServer.Workflow.RunExecutorVfsWiringTest do
  @moduledoc """
  TRD-2026-4212be7e / JSH-T003 / TRD-034 — verifies that
  `ForemanServer.Workflow.RunExecutor` binds `run_id` to its worktree
  root in `VfsIsolation` before any phase body executes, and unbinds
  it when the run's worktree is reclaimed.

  The wiring lives in two places:
    * `foreman_env/2` calls `bind_vfs(state.run_id, worktree_record.worktree_path)`
    * `do_clean_run_worktree/2` and `maybe_stop_shell_session/1` call
      `unbind_vfs(state.run_id)`

  The unbind used to sit in `cleanup_phase_worktree/4`, which ran at every
  phase boundary. A run now has one worktree for its whole execution, so the
  binding must survive every phase and is released once, at finalization.

  These tests exercise the underlying helpers via the
  `@doc false __bind_vfs_for_test__/2` and `__unbind_vfs_for_test__/1`
  exports on the RunExecutor module, which are the production helpers.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.VfsIsolation

  setup do
    case Process.whereis(VfsIsolation) do
      nil -> start_supervised!(VfsIsolation)
      _pid -> :ok
    end

    :ets.delete_all_objects(:foreman_vfs_isolation)
    :ok
  end

  describe "bind_vfs/2 + unbind_vfs/1 wiring helpers" do
    test "bind registers the run_id in VfsIsolation" do
      run_id = "vfs-wiring-#{System.unique_integer([:positive])}"
      worktree = "/tmp/wt-wiring-#{System.unique_integer([:positive])}"

      assert :ok = invoke_bind(run_id, worktree)
      assert {:ok, ^worktree} = VfsIsolation.lookup(run_id)
    end

    test "unbind removes the registration" do
      run_id = "vfs-wiring-#{System.unique_integer([:positive])}"
      worktree = "/tmp/wt-wiring-#{System.unique_integer([:positive])}"

      assert :ok = invoke_bind(run_id, worktree)
      assert {:ok, ^worktree} = VfsIsolation.lookup(run_id)

      assert :ok = invoke_unbind(run_id)
      assert :not_found = VfsIsolation.lookup(run_id)
    end

    test "allowed? returns true inside the bound worktree" do
      run_id = "vfs-wiring-#{System.unique_integer([:positive])}"
      worktree = "/tmp/wt-wiring-#{System.unique_integer([:positive])}"

      :ok = invoke_bind(run_id, worktree)
      assert VfsIsolation.allowed?(run_id, worktree)
      assert VfsIsolation.allowed?(run_id, Path.join(worktree, "sub/dir/file.txt"))
    end

    test "allowed? returns false outside the bound worktree" do
      run_id = "vfs-wiring-#{System.unique_integer([:positive])}"
      worktree = "/tmp/wt-wiring-#{System.unique_integer([:positive])}"

      :ok = invoke_bind(run_id, worktree)
      refute VfsIsolation.allowed?(run_id, "/etc/passwd")
      refute VfsIsolation.allowed?(run_id, Path.join(Path.dirname(worktree), "sibling"))
    end

    test "bind_with_check refuses a worktree outside the allowlist" do
      run_id = "vfs-wiring-#{System.unique_integer([:positive])}"

      assert :ok = invoke_bind(run_id, "/forbidden/path")
      assert :not_found = VfsIsolation.lookup(run_id)
    end

    test "empty run_id is a no-op (defensive guard)" do
      assert :ok = invoke_bind("", "/tmp/wt-x")
      assert :ok = invoke_unbind("")
      assert :ok = invoke_bind("not-binary", "/tmp/wt-y")
    end
  end

  describe "exported test surfaces exist and are wired correctly" do
    # `function_exported?/3` answers false for a module that is merely not
    # LOADED yet, so without this the two assertions below pass or fail on test
    # ordering: they only saw a loaded module when some earlier test in the run
    # had already invoked it. `Code.ensure_loaded!/1` makes the probe answer the
    # question it claims to ask (and raises if the module is genuinely absent).
    setup do
      Code.ensure_loaded!(ForemanServer.Workflow.RunExecutor)
      :ok
    end

    test "RunExecutor exports __bind_vfs_for_test__/2" do
      assert function_exported?(ForemanServer.Workflow.RunExecutor, :__bind_vfs_for_test__, 2)
    end

    test "RunExecutor exports __unbind_vfs_for_test__/1" do
      assert function_exported?(ForemanServer.Workflow.RunExecutor, :__unbind_vfs_for_test__, 1)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp invoke_bind(run_id, worktree_path) do
    apply(ForemanServer.Workflow.RunExecutor, :__bind_vfs_for_test__, [run_id, worktree_path])
  end

  defp invoke_unbind(run_id) do
    apply(ForemanServer.Workflow.RunExecutor, :__unbind_vfs_for_test__, [run_id])
  end
end
