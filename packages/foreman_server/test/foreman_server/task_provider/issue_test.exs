defmodule ForemanServer.TaskProvider.IssueTest do
  use ExUnit.Case, async: true

  alias ForemanServer.TaskProvider.Issue

  test "constructs a fully-populated Issue with all 12 fields" do
    issue = %Issue{
      id: "ISS-123",
      title: "Investigate provider outage",
      status: "open",
      priority: 2,
      dependencies: ["ISS-100", "ISS-101"],
      dependents: [],
      assignee: "agent.smith",
      description: "Detailed problem description",
      notes: "Internal operator notes",
      design: "Relevant design context",
      labels: ["provider", "urgent"],
      metadata: %{provider: "beads", remote_id: "ext-42"}
    }

    assert issue.id == "ISS-123"
    assert issue.title == "Investigate provider outage"
    assert issue.status == "open"
    assert issue.priority == 2
    assert issue.dependencies == ["ISS-100", "ISS-101"]
    assert issue.dependents == []
    assert issue.assignee == "agent.smith"
    assert issue.description == "Detailed problem description"
    assert issue.notes == "Internal operator notes"
    assert issue.design == "Relevant design context"
    assert issue.labels == ["provider", "urgent"]
    assert issue.metadata == %{provider: "beads", remote_id: "ext-42"}
  end

  test "sensitive fields are explicit (not aliased into metadata)" do
    issue = %Issue{
      id: "ISS-124",
      title: "Review task payload",
      status: "ready",
      priority: 1,
      dependencies: [],
      dependents: [],
      assignee: "owner@example.com",
      description: "Contains sensitive task details",
      notes: "Contains reviewer-only notes",
      design: "Contains internal design references",
      labels: ["triage"],
      metadata: %{provider: "beads", external_ref: "bead-124"}
    }

    assert issue.assignee == "owner@example.com"
    assert issue.description == "Contains sensitive task details"
    assert issue.notes == "Contains reviewer-only notes"
    assert issue.design == "Contains internal design references"

    refute Map.has_key?(issue.metadata, :assignee)
    refute Map.has_key?(issue.metadata, :description)
    refute Map.has_key?(issue.metadata, :notes)
    refute Map.has_key?(issue.metadata, :design)
    refute Map.has_key?(issue.metadata, "assignee")
    refute Map.has_key?(issue.metadata, "description")
    refute Map.has_key?(issue.metadata, "notes")
    refute Map.has_key?(issue.metadata, "design")
  end

  test "metadata does not contain keys that have a first-class slot" do
    issue = %Issue{
      id: "ISS-125",
      title: "Slot precedence wins",
      status: "claimed",
      priority: 3,
      dependencies: ["ISS-110"],
      dependents: [],
      assignee: nil,
      description: nil,
      notes: nil,
      design: nil,
      labels: [],
      metadata: %{"id" => "metadata-id", "status" => "metadata-status"}
    }

    assert issue.id == "ISS-125"
    assert issue.status == "claimed"
    assert issue.metadata == %{"id" => "metadata-id", "status" => "metadata-status"}
    refute issue.id == issue.metadata["id"]
    refute issue.status == issue.metadata["status"]
  end

  test "Issue.t/0 type exists" do
    assert Code.ensure_loaded?(Issue) == true
  end
end
