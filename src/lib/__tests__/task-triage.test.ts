import { describe, expect, it } from "vitest";
import { formatTriageReport, triageTask } from "../task-triage.js";

describe("triageTask", () => {
  it("routes localized CLI/status bugs to the small workflow", () => {
    const result = triageTask({
      seedType: "bug",
      seedTitle: "foreman status should show task title and description",
      seedDescription: "Small CLI display bug in the status command output.",
      seedComments: "Local status rendering issue only.",
      seedLabels: ["priority:medium"],
    });

    expect(result.workflowName).toBe("small");
    expect(result.scope).toBe("local");
    expect(result.risk).toBe("low");
    expect(result.score).toBeLessThanOrEqual(20);
  });

  it("routes workflow/orchestration work to the medium workflow", () => {
    const result = triageTask({
      seedType: "feature",
      seedTitle: "Add workflow triage and QA validator routing",
      seedDescription: "Introduce workflow routing, phase retry behavior, and validation improvements.",
      seedComments: "Affects workflow selection and QA behavior.",
      seedLabels: [],
    });

    expect(result.workflowName).toBe("medium");
    expect(result.score).toBeGreaterThan(20);
    expect(result.score).toBeLessThanOrEqual(50);
  });

  it("honors explicit workflow labels", () => {
    const result = triageTask({
      seedType: "bug",
      seedTitle: "Anything",
      seedLabels: ["workflow:default"],
    });

    expect(result.workflowName).toBe("default");
    expect(result.confidence).toBe("high");
  });
});

describe("formatTriageReport", () => {
  it("renders a readable triage summary", () => {
    const input = {
      seedType: "bug",
      seedTitle: "status output fix",
      seedDescription: "Show more task metadata",
      seedComments: "Small status task",
      seedLabels: [],
    };
    const result = triageTask(input);
    const report = formatTriageReport(input, result);

    expect(report).toContain("# Triage Report: status output fix");
    expect(report).toContain(`- Recommended workflow: ${result.workflowName}`);
    expect(report).toContain("## Rationale");
  });
});
