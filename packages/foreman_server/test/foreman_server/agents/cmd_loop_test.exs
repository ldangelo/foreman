defmodule ForemanServer.Agents.CmdLoopTest do
  use ExUnit.Case, async: true
  alias ForemanServer.Agents.CmdLoop

  defmodule StampAction do
    use Jido.Action
    def schema, do: [delta: [type: :integer, required: true, default: 1]]
    def run(params, _ctx), do: {:ok, %{applied: true, delta: params.delta}}
  end

  test "call delegates to Jido.Agent.cmd/2" do
    agent = Jido.Agent.new(actions: [StampAction])
    case CmdLoop.call(agent, StampAction, %{}) do
      {:ok, _updated, _directives} -> :ok
      other -> flunk("expected {{:ok, _, _}}, got #{inspect(other)}")
    end
  end

  test "apply_and_dispatch returns directive count" do
    agent = Jido.Agent.new(actions: [StampAction])
    case CmdLoop.apply_and_dispatch(agent, StampAction, %{}) do
      {:ok, _updated, count} -> assert is_integer(count)
      other -> flunk("expected {{:ok, _, count}}, got #{inspect(other)}")
    end
  end
end
