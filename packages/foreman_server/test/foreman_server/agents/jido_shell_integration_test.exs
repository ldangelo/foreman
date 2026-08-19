defmodule ForemanServer.Agents.JidoShellIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  alias ForemanServer.Agents.JidoShellRunner

  test "shell execution smoke" do
    case JidoShellRunner.execute("echo", ["test"]) do
      {:ok, out, 0} -> assert is_binary(out)
      other -> flunk("got #{inspect(other)}")
    end
  end

  test "session isolation: worktree cwd respected" do
    tmpdir = Path.join(System.tmp_dir!(), "shell-#{System.unique_integer()}")
    File.mkdir_p!(tmpdir)
    case JidoShellRunner.execute("pwd", [], cwd: tmpdir) do
      {:ok, out, 0} -> assert out =~ Path.basename(tmpdir)
      other -> flunk("got #{inspect(other)}")
    end
  end
end
