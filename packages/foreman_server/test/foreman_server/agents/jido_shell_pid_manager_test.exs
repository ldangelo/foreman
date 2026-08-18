defmodule ForemanServer.Agents.JidoShellPidManagerTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.JidoShellRunner

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_shell)
    :ok
  end

  test "stop_session/2 accepts a pid-backed manager" do
    {:ok, manager} = start_supervised({JidoShellRunner, [name: nil]})
    {:ok, session_id} = JidoShellRunner.start_session("pid", manager: manager, owner: self())

    assert JidoShellRunner.tracked?(session_id, manager: manager)
    assert :ok = JidoShellRunner.stop_session(session_id, manager: manager)
    refute JidoShellRunner.tracked?(session_id, manager: manager)
  end
end
