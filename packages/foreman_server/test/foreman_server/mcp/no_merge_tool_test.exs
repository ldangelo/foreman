defmodule ForemanServer.MCP.NoMergeToolTest do
  # The merge gate is operator-only: no MCP tool may merge or approve a PR.
  use ExUnit.Case, async: true

  alias ForemanServer.MCP.Tools

  @merge_pattern ~r/merge|approve/i

  # Tools whose description legitimately mentions these words. Adding a tool
  # here is a deliberate decision about the MCP surface.
  # foreman_thread_stop: its description says "Never merges or approves".
  @allowlist ["foreman_thread_stop"]

  def offenders(tools) do
    for %{name: name, description: description} <- tools,
        name not in @allowlist,
        Regex.match?(@merge_pattern, name) or Regex.match?(@merge_pattern, description) do
      name
    end
  end

  test "no advertised tool name or description mentions merge or approve" do
    assert offenders(Tools.list_tools()) == []
  end

  test "the check can fail: a merge tool in the list is caught" do
    fixture = Tools.list_tools() ++ [%{name: "foreman_run_merge", description: "Merge the PR"}]
    assert offenders(fixture) == ["foreman_run_merge"]
  end
end
