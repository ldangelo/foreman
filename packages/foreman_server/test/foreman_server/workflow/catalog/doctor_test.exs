defmodule ForemanServer.Workflow.Catalog.DoctorTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry
  alias ForemanServer.Test.Support.DoctorStubProvider
  alias ForemanServer.Workflow.Catalog.Doctor

  defp issue(id, issue_type) do
    %Issue{
      id: id,
      title: id,
      status: "open",
      priority: 2,
      dependencies: [],
      dependents: [],
      assignee: nil,
      description: nil,
      notes: nil,
      design: nil,
      labels: [],
      metadata: %{"issue_type" => issue_type}
    }
  end

  defp register_project(project_id, issues) do
    :ok =
      TaskProviderRegistry.register_for_project(project_id, DoctorStubProvider, %{
        issues: issues
      })
  end

  describe "AC-002-1: Doctor reports unmapped issue_types by name" do
    test "coverage_report identifies unmapped types through the registered provider path" do
      project_id = "doctor-unmapped-#{System.unique_integer([:positive])}"

      register_project(project_id, [
        issue("bead-1", "type_a"),
        issue("bead-2", "type_b"),
        issue("bead-3", "unmapped_c")
      ])

      type_map = %{"type_a" => "workflow_a", "type_b" => "workflow_b"}

      assert {:ok, report} = Doctor.coverage_report(project_id, type_map)
      assert %Doctor{} = report
      assert report.unmapped_types == ["unmapped_c"]
      refute report.covered
      assert report.total_issue_types == 3
      assert report.mapped_types == 2
    end

    # AC-002-1 regression: a catalog that maps far more types than a project
    # actually uses must not inflate the coverage count past the project's
    # own actual/mapped intersection (previously counted every mapping in
    # the catalog, producing coverage percentages over 100%).
    test "mapped_types counts only types present in both actual and mapped sets" do
      project_id = "doctor-narrow-catalog-#{System.unique_integer([:positive])}"

      register_project(project_id, [issue("bead-1", "type_a"), issue("bead-2", "type_b")])

      type_map = %{
        "type_a" => "workflow_a",
        "type_b" => "workflow_b",
        "type_c" => "workflow_c",
        "type_d" => "workflow_d"
      }

      assert {:ok, report} = Doctor.coverage_report(project_id, type_map)
      assert report.total_issue_types == 2
      assert report.mapped_types == 2
      assert report.covered
    end

    test "format_ascii displays unmapped types in tree format" do
      report = %Doctor{
        unmapped_types: ["unmapped_c", "unmapped_d"],
        covered: false,
        total_issue_types: 4,
        mapped_types: 2
      }

      output = Doctor.format_ascii(report)

      assert String.contains?(output, "unmapped_c")
      assert String.contains?(output, "unmapped_d")
      assert String.contains?(output, "Unmapped issue_types:")
      assert String.contains?(output, "⚠")
    end

    test "format_json includes unmapped_types array" do
      report = %Doctor{
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
    test "coverage_report with full coverage through the registered provider path" do
      project_id = "doctor-full-coverage-#{System.unique_integer([:positive])}"

      register_project(project_id, [issue("bead-1", "type_a"), issue("bead-2", "type_b")])

      type_map = %{"type_a" => "workflow_a", "type_b" => "workflow_b"}

      assert {:ok, report} = Doctor.coverage_report(project_id, type_map)
      assert report.unmapped_types == []
      assert report.covered
      assert report.total_issue_types == 2
      assert report.mapped_types == 2
    end

    test "format_ascii displays full coverage success message" do
      report = %Doctor{
        unmapped_types: [],
        covered: true,
        total_issue_types: 2,
        mapped_types: 2
      }

      output = Doctor.format_ascii(report)

      assert String.contains?(output, "✓")
      assert String.contains?(output, "All issue_types are mapped")
      refute String.contains?(output, "Unmapped issue_types:")
    end

    test "format_json with full coverage" do
      report = %Doctor{
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

  describe "AC-002-3: Doctor cannot report a plausible success from undetermined input" do
    test "coverage_report returns an error when the project has no registered provider" do
      project_id = "doctor-unregistered-#{System.unique_integer([:positive])}"

      assert {:error, _reason} = Doctor.coverage_report(project_id, %{"type_a" => "workflow_a"})
    end
  end

  describe "Format output helpers" do
    test "format_ascii includes coverage percentage" do
      report = %Doctor{
        unmapped_types: [],
        covered: true,
        total_issue_types: 10,
        mapped_types: 7
      }

      output = Doctor.format_ascii(report)

      assert String.contains?(output, "Coverage:")
      assert String.contains?(output, "70%")
    end

    test "format_json roundtrips cleanly" do
      report = %Doctor{
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
