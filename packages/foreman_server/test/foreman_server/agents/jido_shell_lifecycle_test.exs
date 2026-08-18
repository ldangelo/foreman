defmodule ForemanServer.Agents.JidoShellLifecycleTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.JidoShellRunner

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_shell)
    :ok
  end

  setup do
    unique = :erlang.unique_integer([:positive])
    manager = :"JidoShellRunner.Lifecycle.#{unique}"
    start_supervised!({JidoShellRunner, [name: manager]})
    %{manager: manager}
  end

  test "owner exit tears down tracked session", %{manager: manager} do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, session_id} = JidoShellRunner.start_session("owner", manager: manager, owner: owner)

    assert JidoShellRunner.tracked?(session_id, manager: manager)

    Process.exit(owner, :kill)

    assert_eventually(fn -> JidoShellRunner.tracked?(session_id, manager: manager) == false end)
    assert match?({:error, _}, JidoShellRunner.run_command(session_id, "pwd"))
  end

  test "tracked? uses the selected manager, not the default name", %{manager: manager} do
    {:ok, session_id} = JidoShellRunner.start_session("custom", manager: manager, owner: self())

    try do
      assert JidoShellRunner.tracked?(session_id, manager: manager)
    after
      JidoShellRunner.stop_session(session_id, manager: manager)
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, 0) do
    assert fun.()
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
