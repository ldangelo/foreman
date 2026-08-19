defmodule ForemanServer.Workflow.ErrorReporterTest do
  use ExUnit.Case, async: true
  alias ForemanServer.Workflow.ErrorReporter

  describe "top-level errors" do
    test "unknown skill includes skill name and known skill list" do
      msg = ErrorReporter.report({:unknown_skill, "totally-bogus"})
      assert msg =~ "Unknown skill"
      assert msg =~ "totally-bogus"
      assert msg =~ "ensemble-fix-issue"
    end

    test "missing_name" do
      assert ErrorReporter.report(:missing_name) =~
               "'name'"
    end

    test "missing_phases" do
      assert ErrorReporter.report(:missing_phases) =~
               "'phases'"
    end

    test "empty_phases" do
      assert ErrorReporter.report(:empty_phases) =~
               "empty"
    end
  end

  describe "phase-level errors" do
    test "missing_phase_name includes index" do
      msg = ErrorReporter.report({:missing_phase_name, 0})
      assert msg =~ "Phase 0"
      assert msg =~ "'name'"
    end

    test "missing_phase_action includes index" do
      msg = ErrorReporter.report({:missing_phase_action, 1})
      assert msg =~ "Phase 1"
      assert msg =~ "command"
    end
  end

  describe "unknown errors" do
    test "unknown reason falls through to inspect" do
      msg = ErrorReporter.report(:some_unknown_atom)
      assert msg =~ "Workflow error"
      assert msg =~ "some_unknown_atom"
    end
  end
end
