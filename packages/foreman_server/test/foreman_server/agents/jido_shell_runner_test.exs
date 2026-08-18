defmodule ForemanServer.Agents.JidoShellRunnerTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.JidoShellRunner` — the JSH-T001/JSH-T002
  Foreman wrapper around `Jido.Shell.ShellSession`.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.JidoShellRunner

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_shell)
    :ok
  end

  setup do
    unique = :erlang.unique_integer([:positive])
    manager = :"JidoShellRunner.Test.#{unique}"
    start_supervised!({JidoShellRunner, [name: manager]})
    %{manager: manager}
  end

  describe "start_session/2" do
    test "returns {:ok, session_id}", %{manager: manager} do
      assert {:ok, session_id} = JidoShellRunner.start_session("test", manager: manager)
      assert is_binary(session_id)
      refute JidoShellRunner.tracked?(session_id, manager: manager)
      on_exit(fn -> JidoShellRunner.stop_session(session_id, manager: manager) end)
    end

    test "tracks owner-bound sessions under the selected manager", %{manager: manager} do
      assert {:ok, session_id} =
               JidoShellRunner.start_session("owner", manager: manager, owner: self())

      try do
        assert JidoShellRunner.tracked?(session_id, manager: manager)
      after
        JidoShellRunner.stop_session(session_id, manager: manager)
      end
    end
  end

  describe "run_command/2" do
    test "returns {:ok, :accepted} for a real session", %{manager: manager} do
      {:ok, session_id} = JidoShellRunner.start_session("test", manager: manager)

      try do
        assert {:ok, :accepted} = JidoShellRunner.run_command(session_id, "pwd")
      after
        JidoShellRunner.stop_session(session_id, manager: manager)
      end
    end

    test "returns an error tag for a non-existent session" do
      result = JidoShellRunner.run_command("nonexistent-session-xyz", "pwd")
      assert match?({:error, _}, result)
    end
  end

  describe "stop_session/2" do
    test "returns :ok for a real session and clears tracking", %{manager: manager} do
      {:ok, session_id} = JidoShellRunner.start_session("test", manager: manager, owner: self())
      assert :ok = JidoShellRunner.stop_session(session_id, manager: manager)
      refute JidoShellRunner.tracked?(session_id, manager: manager)
    end
  end
end
