defmodule ForemanServer.Agents.McpDiagnosticsTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Agents.McpDiagnostics

  test "capture without raw body" do
    diag = McpDiagnostics.capture("ep-1", "tool-1", "corr-1", :parse_error, "{not json}")

    assert diag.endpoint_id == "ep-1"
    assert diag.tool_id == "tool-1"
    assert diag.correlation_id == "corr-1"
    assert diag.error_kind == :parse_error
    assert diag.response_size == byte_size("{not json}")
    assert is_binary(diag.response_hash)
    assert String.length(diag.response_hash) == 16
    assert diag.raw_body_included == false
  end

  test "capture with include_raw_body policy" do
    diag =
      McpDiagnostics.capture(
        "ep-1",
        "tool-1",
        "corr-1",
        :schema_error,
        "{}",
        debug_policy: [:include_raw_body]
      )

    assert diag.raw_body_included == true
  end
end
