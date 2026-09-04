defmodule ForemanServer.Agents.JidoShellRunnerTest do
  use ExUnit.Case, async: true
  alias ForemanServer.Agents.JidoShellRunner

  test "execute runs a benign command" do
    case JidoShellRunner.execute("echo", ["hello"]) do
      {:ok, _output, 0} -> :ok
      other -> flunk("expected ok tuple, got #{inspect(other)}")
    end
  end
end
