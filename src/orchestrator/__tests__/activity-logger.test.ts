import { describe, it, expect } from "vitest";

import {
  createPhaseRecord,
  detectWarnings,
  finalizePhaseRecord,
} from "../activity-logger.js";

describe("activity logger observability", () => {
  it("tracks command phase metadata including expected artifact", () => {
    const record = createPhaseRecord("fix", "MiniMax", {
      phaseType: "command",
      commandsRun: ["/ensemble:fix-issue Example bug"],
      artifactExpected: "DEVELOPER_REPORT.md",
    });

    expect(record.phaseType).toBe("command");
    expect(record.commandsRun).toEqual(["/ensemble:fix-issue Example bug"]);
    expect(record.artifactExpected).toBe("DEVELOPER_REPORT.md");
  });

  it("warns when a successful phase is missing its expected artifact", () => {
    const finalized = finalizePhaseRecord(
      {
        ...createPhaseRecord("fix", "MiniMax", {
          phaseType: "command",
          artifactExpected: "DEVELOPER_REPORT.md",
        }),
        artifactPresent: false,
      },
      {
        success: true,
        costUsd: 0.1,
        turns: 3,
      },
    );

    expect(detectWarnings([finalized])).toContain(
      "Missing phase artifacts: fix -> DEVELOPER_REPORT.md",
    );
  });

  it("warns when a command phase lacks strong execution evidence", () => {
    const finalized = finalizePhaseRecord(
      {
        ...createPhaseRecord("fix", "MiniMax", {
          phaseType: "command",
          artifactExpected: "DEVELOPER_REPORT.md",
        }),
        commandHonored: false,
      },
      {
        success: true,
        costUsd: 0.1,
        turns: 3,
      },
    );

    expect(detectWarnings([finalized])).toContain(
      "Command phases without strong execution evidence: fix",
    );
  });

  it("warns explicitly on command phase contract failures", () => {
    const finalized = finalizePhaseRecord(
      createPhaseRecord("fix", "MiniMax", {
        phaseType: "command",
        artifactExpected: "DEVELOPER_REPORT.md",
      }),
      {
        success: false,
        costUsd: 0.1,
        turns: 3,
        error: "Command phase contract violated: Expected artifact missing: DEVELOPER_REPORT.md",
      },
    );

    expect(detectWarnings([finalized])).toContain(
      "Command phase contract failures: fix",
    );
  });

  it("records builtin phase type with workflow metadata", () => {
    const record = createPhaseRecord("create-pr", "builtin", {
      phaseType: "builtin",
      artifactExpected: "PR_METADATA.json",
      workflowName: "default",
      workflowPath: ".foreman/workflows/default.yaml",
    });

    expect(record.name).toBe("create-pr");
    expect(record.phaseType).toBe("builtin");
    expect(record.artifactExpected).toBe("PR_METADATA.json");
    expect(record.workflowName).toBe("default");
    expect(record.workflowPath).toBe(".foreman/workflows/default.yaml");
  });

  it("finalizePhaseRecord carries builtin phase type and workflow info through to result", () => {
    const record = createPhaseRecord("create-pr", "builtin", {
      phaseType: "builtin",
      artifactExpected: "PR_METADATA.json",
      workflowName: "default",
      workflowPath: ".foreman/workflows/default.yaml",
    });

    const finalized = finalizePhaseRecord(record, {
      success: true,
      costUsd: 0,
      turns: 0,
      workflowName: "default",
      workflowPath: ".foreman/workflows/default.yaml",
    });

    expect(finalized.phaseType).toBe("builtin");
    expect(finalized.workflowName).toBe("default");
    expect(finalized.workflowPath).toBe(".foreman/workflows/default.yaml");
    expect(finalized.verdict).toBe("pass");
  });
});
