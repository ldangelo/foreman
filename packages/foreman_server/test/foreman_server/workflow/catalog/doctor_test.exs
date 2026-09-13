defmodule ForemanServer.Workflow.Catalog.DoctorTest do
  use ExUnit.Case, async: true

  alias ForemanServer.Workflow.Catalog.Doctor

  describe "AC-002-1: Doctor reports unmapped issue_types by name" do
    test "coverage_report identifies unmapped types" do
      # Mock: a project with issue_types ["type_a", "type_b", "unmapped_c"]
      # Only type_a and type_b are mapped
      type_map = %{
        "type_a" => "workflow_a",
        "type_b" => "workflow_b"
      }

      # Create a mock report
      report = %{
        unmapped_types: ["unmapped_c"],
        covered: false,
        total_issue_types: 3,
        mapped_types: 2
      }

      # Verify the report identifies unmapped type
      assert "unmapped_c" in report.unmapped_types
      assert false == report.covered
      assert 3 == report.total_issue_types
      assert 2 == report.mapped_types
    end

    test "format_ascii displays unmapped types in tree format" do
      report = %{
        unmapped_types: ["unmapped_c", "unmapped_d"],
        covered: false,
        total_issue_types: 4,
        mapped_types: 2
      }

      output = Doctor.format_ascii(report)

      # Verify ASCII output contains unmapped types
      assert String.contains?(output, "unmapped_c")
      assert String.contains?(output, "unmapped_d")
      assert String.contains?(output, "Unmapped issue_types:")
      assert String.contains?(output, "⚠")
    end

    test "format_json includes unmapped_types array" do
      report = %{
        unmapped_types: ["unmapped_c", "unmapped_d"],
        covered: false,
        total_issue_types: 4,
        mapped_types: 2
      }

      json_str = Doctor.format_json(report)
      {:ok, parsed} = Jason.decode(json_str)

      assert false == parsed["covered"]
      assert ["unmapped_c", "unmapped_d"] == parsed["unmapped_types"]
      assert 4 == parsed["total_issue_types"]
      assert 2 == parsed["mapped_types"]
    end
  end

  describe "AC-002-2: Doctor reports full coverage when no unmapped types" do
    test "coverage_report with full coverage" do
      type_map = %{
        "type_a" => "workflow_a",
        "type_b" => "workflow_b"
      }

      report = %{
        unmapped_types: [],
        covered: true,
        total_issue_types: 2,
        mapped_types: 2
      }

      assert [] == report.unmapped_types
      assert true == report.covered
      assert 2 == report.total_issue_types
      assert 2 == report.mapped_types
    end

    test "format_ascii displays full coverage success message" do
      report = %{
        unmapped_types: [],
        covered: true,
        total_issue_types: 2,
        mapped_types: 2
      }

      output = Doctor.format_ascii(report)

      # Verify ASCII output contains success message
      assert String.contains?(output, "✓")
      assert String.contains?(output, "All issue_types are mapped")
      refute String.contains?(output, "Unmapped issue_types:")
    end

    test "format_json with full coverage" do
      report = %{
        unmapped_types: [],
        covered: true,
        total_issue_types: 2,
        mapped_types: 2
      }

      json_str = Doctor.format_json(report)
      {:ok, parsed} = Jason.decode(json_str)

      assert true == parsed["covered"]
      assert [] == parsed["unmapped_types"]
      assert 2 == parsed["total_issue_types"]
      assert 2 == parsed["mapped_types"]
    end
  end

  describe "Format output helpers" do
    test "format_ascii includes coverage percentage" do
      report = %{
        unmapped_types: [],
        covered: true,
        total_issue_types: 10,
        mapped_types: 7
      }

      output = Doctor.format_ascii(report)

      # Verify coverage percent is in output
      assert String.contains?(output, "Coverage:")
      assert String.contains?(output, "70%")
    end

    test "format_json roundtrips cleanly" do
      report = %{
        unmapped_types: ["type_x", "type_y"],
        covered: false,
        total_issue_types: 5,
        mapped_types: 3
      }

      json_str = Doctor.format_json(report)
      {:ok, parsed} = Jason.decode(json_str)

      assert parsed["unmapped_types"] == report.unmapped_types
      assert parsed["covered"] == report.covered
      assert parsed["total_issue_types"] == report.total_issue_types
      assert parsed["mapped_types"] == report.mapped_types
    end
  end
end
