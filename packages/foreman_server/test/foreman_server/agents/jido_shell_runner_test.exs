defmodule ForemanServer.Agents.JidoShellRunnerTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.JidoShellRunner` — the JSH-T001
  Foreman wrapper around `Jido.Shell.ShellSession`
  (TRD-2026-4212be7e).

  The tests assert the *real* Jido.Shell contract:
    - `start_session/1` returns `{:ok, session_id}` (the id passed in)
    - `run_command/2` returns `{:ok, :accepted}` (async ack)
    - `stop_session/1` returns `:ok`

  The actual command result is delivered asynchronously as a
  `:command_finished` message. Asserting that requires hooking a
  callback (Jido.Shell option); this test verifies the
  acknowledgement contract only.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.JidoShellRunner

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_shell)
    :ok
  end

  describe "start_session/1 (uses start_with_vfs/2)" do
    test "returns {:ok, session_id}" do
      assert {:ok, session_id} = JidoShellRunner.start_session("test")
      assert is_binary(session_id)

      # Cleanup
      on_exit(fn -> JidoShellRunner.stop_session(session_id) end)
    end
  end

  describe "run_command/2 (async ack contract)" do
    test "returns {:ok, :accepted} for a real session" do
      {:ok, session_id} = JidoShellRunner.start_session("test")

      try do
        # Real upstream contract: {:ok, :accepted}. The actual
        # result is delivered via a :command_finished message
        # asynchronously.
        assert {:ok, :accepted} = JidoShellRunner.run_command(session_id, "pwd")
      after
        JidoShellRunner.stop_session(session_id)
      end
    end

    test "returns an error tag for a non-existent session" do
      result = JidoShellRunner.run_command("nonexistent-session-xyz", "pwd")
      assert match?({:error, _}, result)
    end
  end

  describe "stop_session/1" do
    test "returns :ok for a real session" do
      {:ok, session_id} = JidoShellRunner.start_session("test")
      assert :ok = JidoShellRunner.stop_session(session_id)
    end
  end
end
