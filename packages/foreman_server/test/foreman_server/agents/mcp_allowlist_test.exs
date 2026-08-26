defmodule ForemanServer.Agents.McpAllowlistTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Agents.McpAllowlist

  test "denies unknown tool" do
    {:ok, _pid} = McpAllowlist.start_link()
    refute McpAllowlist.permit?("unknown-tool")
    assert McpAllowlist.denied_count() >= 1
  end

  test "allows whitelisted tool" do
    {:ok, _pid} = McpAllowlist.start_link()
    :ok = McpAllowlist.add("git")
    assert McpAllowlist.permit?("git")
    assert "git" in McpAllowlist.list()
  end

  test "remove takes tool off the allowlist" do
    {:ok, _pid} = McpAllowlist.start_link()
    :ok = McpAllowlist.add("git")
    :ok = McpAllowlist.remove("git")
    refute McpAllowlist.permit?("git")
  end
end