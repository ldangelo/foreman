defmodule ForemanServer.Agents.McpIntegrationTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.{
    McpAllowlist,
    McpClientPool,
    McpDiagnostics,
    McpErrorHandler,
    McpToolSync
  }

  test "tool sync across multiple servers" do
    {:ok, _sync} = McpToolSync.start_link()
    {:ok, _pool} = McpClientPool.start_link()

    assert :ok = McpToolSync.sync(["srv-a", "srv-b"])
    assert is_list(McpToolSync.tools_for("srv-a"))
    assert is_list(McpToolSync.tools_for("srv-b"))
  end

  test "malformed response diagnostics bounded" do
    diag = McpDiagnostics.capture("ep", "tool", "corr", :parse_error, "{bad}")

    assert diag.response_size == byte_size("{bad}")
    assert diag.raw_body_included == false
    assert is_binary(diag.response_hash)
    assert String.length(diag.response_hash) == 16
  end

  test "allowlist denies unknown tool" do
    {:ok, _pid} = McpAllowlist.start_link()
    :ok = McpAllowlist.add("git")

    assert McpAllowlist.permit?("git")
    refute McpAllowlist.permit?("dangerous")
  end

  test "error handler classifies recoverable vs non-recoverable" do
    assert {:retry, retry_dir} = McpErrorHandler.handle(:timeout)
    assert retry_dir.action == :retry

    assert {:escalate, esc_dir} = McpErrorHandler.handle(:permission_denied)
    assert esc_dir.action == :escalate
  end
end
