defmodule ForemanServer.Workflow.ErrorReporterTest do
  use ExUnit.Case, async: true
  alias ForemanServer.Workflow.ErrorReporter
  test "formats unknown skill" do
    msg = ErrorReporter.report({:unknown_skill, "bogus"})
    assert msg =~ "Unknown skill"
    assert msg =~ "bogus"
  end
  test "formats missing id" do
    assert ErrorReporter.report(:missing_id) =~ "id"
  end
end