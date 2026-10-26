defmodule ForemanServer.Approvals.ClaudeCliTest do
  # `ClaudeCli.permission_prompt_tool/1` starts the claude CLI Foreman launches (`FOREMAN_CLAUDE_CLI`,
  # else `claude` on the PATH) with `--permission-prompt-tool` and no value and reads the CLI's own
  # parse error (foreman-dc618). The fakes print what the real CLIs print.
  use ExUnit.Case, async: false

  alias ForemanServer.Approvals.ClaudeCli
  alias ForemanServer.TestSupport.FakeClaudeCli

  @flag "--permission-prompt-tool"

  setup do
    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)
    :ok
  end

  @tag :tmp_dir
  test "a CLI that knows the flag is supported, and is started with the flag alone", %{
    tmp_dir: dir
  } do
    cli = FakeClaudeCli.write!(dir, "claude-known", :known)
    FakeClaudeCli.use!(cli)

    assert ClaudeCli.permission_prompt_tool() == :supported
    assert FakeClaudeCli.calls(cli) == [@flag]
  end

  @tag :tmp_dir
  test "a CLI that rejects the flag as unknown is unsupported, and names itself", %{tmp_dir: dir} do
    cli = FakeClaudeCli.write!(dir, "claude-old", :unknown)
    FakeClaudeCli.use!(cli)

    assert ClaudeCli.permission_prompt_tool() == {:unsupported, cli}
  end

  @tag :tmp_dir
  test "without FOREMAN_CLAUDE_CLI, or with it empty, it is the claude on the PATH", %{
    tmp_dir: dir
  } do
    cli = FakeClaudeCli.write!(dir, "claude", :unknown)
    System.put_env("PATH", dir <> ":" <> System.get_env("PATH"))

    FakeClaudeCli.use!("")
    assert ClaudeCli.permission_prompt_tool() == {:unsupported, cli}

    System.delete_env("FOREMAN_CLAUDE_CLI")
    assert ClaudeCli.permission_prompt_tool() == {:unsupported, cli}
  end

  @tag :tmp_dir
  test "a CLI that is not there cannot be probed", %{tmp_dir: dir} do
    missing = Path.join(dir, "no-such-claude")
    FakeClaudeCli.use!(missing)

    assert ClaudeCli.permission_prompt_tool() == {:unknown, {:not_installed, missing}}
  end

  @tag :tmp_dir
  test "anything but the two parse errors is no verdict", %{tmp_dir: dir} do
    FakeClaudeCli.use!(FakeClaudeCli.write!(dir, "claude-chatty", "echo hello\n"))
    assert ClaudeCli.permission_prompt_tool() == {:unknown, {:unrecognised_output, "hello\n"}}

    FakeClaudeCli.use!(
      FakeClaudeCli.write!(dir, "claude-other", "echo 'error: something else' >&2\nexit 2\n")
    )

    assert ClaudeCli.permission_prompt_tool() ==
             {:unknown, {:unrecognised_output, "error: something else\n"}}
  end

  @tag :tmp_dir
  test "a CLI that never answers is stopped and gives no verdict", %{tmp_dir: dir} do
    FakeClaudeCli.use!(FakeClaudeCli.write!(dir, "claude-hung", "sleep 60\n"))

    started = System.monotonic_time(:millisecond)

    assert ClaudeCli.permission_prompt_tool(timeout_ms: 300) ==
             {:unknown, {:probe_failed, :timed_out}}

    assert System.monotonic_time(:millisecond) - started < 10_000
  end
end
