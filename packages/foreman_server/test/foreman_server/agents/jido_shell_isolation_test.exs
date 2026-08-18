defmodule ForemanServer.Agents.JidoShellIsolationTest do
  @moduledoc """
  Tests for JSH-T003 (VFS isolation per worktree). The actual
  worktree-mounted VFS lands in JSH-T003 proper; the bounded
  slice here is the per-session isolation contract: two distinct
  sessions must have distinct session_ids and therefore distinct
  in-memory VFS roots. Upstream `Jido.Shell` generates opaque
  session ids, so this test asserts uniqueness rather than a
  caller-controlled prefix.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.JidoShellRunner

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_shell)
    :ok
  end

  setup do
    unique = :erlang.unique_integer([:positive])
    manager = :"JidoShellRunner.Isolation.#{unique}"
    start_supervised!({JidoShellRunner, [name: manager]})
    %{manager: manager}
  end

  test "two shell sessions get distinct session_ids (the VFS root key)", %{manager: manager} do
    {:ok, s1} = JidoShellRunner.start_session("iso", manager: manager)
    {:ok, s2} = JidoShellRunner.start_session("iso", manager: manager)

    try do
      assert is_binary(s1)
      assert is_binary(s2)
      assert s1 != s2
    after
      JidoShellRunner.stop_session(s1, manager: manager)
      JidoShellRunner.stop_session(s2, manager: manager)
    end
  end
end
