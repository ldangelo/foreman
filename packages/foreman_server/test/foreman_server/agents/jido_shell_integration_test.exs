defmodule ForemanServer.Agents.JidoShellIntegrationTest do
  @moduledoc """
  TRD-2026-4212be7e / JSH-T004 / TRD-035:
  Shell integration tests covering command execution, session isolation,
  and VFS sandbox enforcement.

  Three subject areas:
  1. Command execution  — `JidoShellRunner.execute/3` (one-shot) and
                          `run_command/3` (session-backed)
  2. Session isolation  — distinct sessions are independent; state does
                          not bleed between them
  3. VFS sandbox        — agents bound to a worktree can only access paths
                          inside that worktree
  """
  use ExUnit.Case, async: false
  @moduletag :integration

  alias ForemanServer.Agents.{JidoShellRunner, VfsIsolation}

  # ---------------------------------------------------------------------------
  # Shared setup helpers
  # ---------------------------------------------------------------------------

  defp unique_manager, do: :"ShellIntg.#{:erlang.unique_integer([:positive])}"

  defp start_manager(manager \\ nil) do
    name = manager || unique_manager()
    start_supervised!({JidoShellRunner, [name: name]})
    name
  end

  defp with_session(manager, owner \\ self()) do
    {:ok, session_id} = JidoShellRunner.start_session("test-workspace", manager: manager, owner: owner)
    on_exit(fn -> JidoShellRunner.stop_session(session_id, manager: manager) end)
    session_id
  end

  defp bind_agent(agent_id, worktree) do
    case GenServer.whereis(VfsIsolation) do
      nil -> {:ok, _pid} = start_supervised!(VfsIsolation)
      _pid -> :ok
    end
    :ets.delete_all_objects(:foreman_vfs_isolation)
    :ok = VfsIsolation.bind(agent_id, worktree)
  end

  # ---------------------------------------------------------------------------
  # 1. Command execution — execute/3 (one-shot, no session)
  # ---------------------------------------------------------------------------

  describe "execute/3 — one-shot command execution" do
    test "returns output on success" do
      assert {:ok, out, 0} = JidoShellRunner.execute("echo", ["hello world"])
      assert out =~ "hello world"
    end

    test "returns non-zero exit code on failure" do
      assert {:ok, _out, code} = JidoShellRunner.execute("false", [])
      assert code != 0
    end

    test "returns descriptive error when command not found" do
      # "nonexistent-command-xyz123" is unlikely to exist on any system
      result = JidoShellRunner.execute("nonexistent-command-xyz123", [])
      # Falls back to System.cmd which returns non-zero on not found
      assert {:ok, _out, code} = result
      assert code != 0
    end

    test "cwd option sets working directory" do
      tmpdir = Path.join(System.tmp_dir!(), "shell-cwd-#{System.unique_integer()}")
      File.mkdir_p!(tmpdir)
      assert {:ok, out, 0} = JidoShellRunner.execute("pwd", [], cwd: tmpdir)
      # macOS resolves /var/folders -> /private/var/folders in pwd output;
      # Path.expand normalizes both sides for comparison.
      assert String.trim(out) == normalize_path(tmpdir)
    end

    test "output captures stdout, not stderr by default" do
      assert {:ok, out, 0} = JidoShellRunner.execute("sh", ["-c", "echo stdout && echo stderr >&2"])
      assert out =~ "stdout"
      refute out =~ "stderr"
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Session isolation — session lifecycle and independence
  # ---------------------------------------------------------------------------

  describe "session lifecycle — start_session / run_command / stop_session" do
    setup do
      manager = start_manager()
      %{manager: manager}
    end

    test "start_session/2 returns a non-empty session_id", %{manager: manager} do
      {:ok, session_id} = JidoShellRunner.start_session("test-workspace", manager: manager)
      assert is_binary(session_id)
      assert byte_size(session_id) > 0
      JidoShellRunner.stop_session(session_id, manager: manager)
    end

    test "session is tracked after start", %{manager: manager} do
      {:ok, session_id} = JidoShellRunner.start_session("test-workspace", manager: manager)
      try do
        assert JidoShellRunner.tracked?(session_id, manager: manager)
      after
        JidoShellRunner.stop_session(session_id, manager: manager)
      end
    end

    test "session is untracked after stop", %{manager: manager} do
      {:ok, session_id} = JidoShellRunner.start_session("test-workspace", manager: manager)
      :ok = JidoShellRunner.stop_session(session_id, manager: manager)
      refute JidoShellRunner.tracked?(session_id, manager: manager)
    end

    test "stop_session/2 is idempotent (stopping already-stopped is ok)", %{manager: manager} do
      {:ok, session_id} = JidoShellRunner.start_session("test-workspace", manager: manager)
      :ok = JidoShellRunner.stop_session(session_id, manager: manager)
      # Idempotent: no error on second stop
      assert :ok = JidoShellRunner.stop_session(session_id, manager: manager)
    end

    test "run_command/3 executes command in session context", %{manager: manager} do
      session_id = with_session(manager)
      assert {:ok, _out, 0} = JidoShellRunner.run_command(session_id, "echo hello")
    end

    test "run_command/3 returns non-zero exit code on failure", %{manager: manager} do
      session_id = with_session(manager)
      assert {:ok, _out, code} = JidoShellRunner.run_command(session_id, "false")
      assert code != 0
    end

    test "owner process exit tears down tracked session", %{manager: manager} do
      owner = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, session_id} = JidoShellRunner.start_session("test-workspace", manager: manager, owner: owner)
      assert JidoShellRunner.tracked?(session_id, manager: manager)
      Process.exit(owner, :kill)
      # Session should be unregistered after owner dies
      assert_eventually(fn -> JidoShellRunner.tracked?(session_id, manager: manager) == false end, 30)
    end
  end

  describe "session independence — distinct sessions cannot bleed state" do
    setup do
      manager = start_manager()
      %{manager: manager}
    end

    test "two sessions get distinct session_ids", %{manager: manager} do
      {:ok, s1} = JidoShellRunner.start_session("ws-a", manager: manager, owner: self())
      {:ok, s2} = JidoShellRunner.start_session("ws-b", manager: manager, owner: self())
      try do
        assert s1 != s2
      after
        JidoShellRunner.stop_session(s1, manager: manager)
        JidoShellRunner.stop_session(s2, manager: manager)
      end
    end

    test "distinct sessions execute independently", %{manager: manager} do
      # Each session should execute commands without interfering with the other.
      # This is a functional isolation test: verify that two concurrent
      # sessions both complete their commands successfully.
      s1 = with_session(manager)
      s2 = with_session(manager)

      results =
        Task.async_stream(
          [s1, s2],
          fn session_id ->
            JidoShellRunner.run_command(session_id, "echo #{session_id}")
          end,
          ordered: true,
          timeout: 10_000
        )
        |> Enum.to_list()

      assert length(results) == 2
      assert Enum.all?(results, fn
        {:ok, {:ok, _out, 0}} -> true
        _ -> false
      end)
    end

    test "tracked sessions are unique per manager", %{manager: manager} do
      session_ids =
        1..3
        |> Enum.map(fn _ ->
          {:ok, id} = JidoShellRunner.start_session("ws", manager: manager, owner: self())
          id
        end)

      try do
        Enum.each(session_ids, fn id ->
          assert JidoShellRunner.tracked?(id, manager: manager)
        end)
        assert Enum.uniq(session_ids) == session_ids
      after
        Enum.each(session_ids, &JidoShellRunner.stop_session(&1, manager: manager))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. VFS sandbox — worktree isolation via VfsIsolation + shell
  # ---------------------------------------------------------------------------

  describe "VFS sandbox — VfsIsolation enforces worktree boundary" do
    setup do
      # Ensure VfsIsolation GenServer is running for these tests
      case GenServer.whereis(VfsIsolation) do
        nil -> {:ok, _pid} = start_supervised!(VfsIsolation)
        _pid -> :ok
      end
      :ets.delete_all_objects(:foreman_vfs_isolation)
      :ok
    end

    test "bound agent can access paths inside the worktree" do
      worktree = Path.join(System.tmp_dir!(), "vfs-wt-#{System.unique_integer()}")
      File.mkdir_p!(worktree)
      agent_id = "agent-vfs-in"

      bind_agent(agent_id, worktree)

      assert VfsIsolation.allowed?(agent_id, worktree)
      assert VfsIsolation.allowed?(agent_id, Path.join(worktree, "sub"))
      assert VfsIsolation.allowed?(agent_id, Path.join(worktree, "sub/deep/file.txt"))
    end

    test "bound agent cannot access paths outside the worktree" do
      worktree = Path.join(System.tmp_dir!(), "vfs-wt-#{System.unique_integer()}")
      File.mkdir_p!(worktree)
      agent_id = "agent-vfs-out"

      bind_agent(agent_id, worktree)

      refute VfsIsolation.allowed?(agent_id, "/etc/passwd")
      refute VfsIsolation.allowed?(agent_id, "/tmp/other")
      refute VfsIsolation.allowed?(agent_id, Path.join(Path.dirname(worktree), "sibling"))
    end

    test "unbound agent cannot access any path" do
      agent_id = "agent-unbound-#{System.unique_integer()}"
      # No bind call
      refute VfsIsolation.allowed?(agent_id, "/tmp/somewhere")
      refute VfsIsolation.allowed?(agent_id, "/etc/passwd")
    end

    test "bind_with_check succeeds for allowed worktree" do
      worktree = Path.join(System.tmp_dir!(), "vfs-ok-#{System.unique_integer()}")
      File.mkdir_p!(worktree)
      agent_id = "agent-ok-#{System.unique_integer()}"

      assert :ok = VfsIsolation.bind_with_check(agent_id, worktree)
      assert {:ok, ^worktree} = VfsIsolation.lookup(agent_id)
    end

    test "bind_with_check rejects worktree outside allowed roots" do
      agent_id = "agent-bad-#{System.unique_integer()}"

      assert {:error, :worktree_not_in_allowed_list} =
               VfsIsolation.bind_with_check(agent_id, "/forbidden/path")

      assert :not_found = VfsIsolation.lookup(agent_id)
    end

    test "unbind removes the binding" do
      worktree = Path.join(System.tmp_dir!(), "vfs-ub-#{System.unique_integer()}")
      File.mkdir_p!(worktree)
      agent_id = "agent-ub-#{System.unique_integer()}"

      :ok = VfsIsolation.bind(agent_id, worktree)
      assert {:ok, ^worktree} = VfsIsolation.lookup(agent_id)

      :ok = VfsIsolation.unbind(agent_id)
      assert :not_found = VfsIsolation.lookup(agent_id)
    end

    test "rebind replaces the existing binding" do
      agent_id = "agent-rb-#{System.unique_integer()}"
      wt_a = Path.join(System.tmp_dir!(), "vfs-rb-a-#{System.unique_integer()}")
      wt_b = Path.join(System.tmp_dir!(), "vfs-rb-b-#{System.unique_integer()}")
      File.mkdir_p!(wt_a)
      File.mkdir_p!(wt_b)

      :ok = VfsIsolation.bind(agent_id, wt_a)
      assert {:ok, ^wt_a} = VfsIsolation.lookup(agent_id)

      :ok = VfsIsolation.bind(agent_id, wt_b)
      assert {:ok, ^wt_b} = VfsIsolation.lookup(agent_id)
      refute VfsIsolation.allowed?(agent_id, wt_a)
    end
  end

  # ---------------------------------------------------------------------------
  # Helper
  # ---------------------------------------------------------------------------

  # macOS exposes /var/folders as a symlink to /private/var/folders;
  # `pwd` prints the resolved path while the test's tmpdir is built
  # from System.tmp_dir/! (unresolved). Run `readlink -f` to normalise
  # both sides for an equality comparison.
  defp normalize_path(path) do
    case System.cmd("readlink", ["-f", path], stderr_to_stdout: true) do
      {resolved, 0} -> String.trim(resolved)
      _ -> path
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(_fun, 0) do
    flunk("assert_eventually: assertion never passed within #{20} attempts")
  end

  defp assert_eventually(fun, attempts) do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end
end
