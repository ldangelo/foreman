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

  it("tracks builtin phase type correctly", () => {
    const record = createPhaseRecord("create-pr", undefined, {
      phaseType: "builtin",
      artifactExpected: "docs/reports/foreman-abc/PR_METADATA.json",
    });

    expect(record.phaseType).toBe("builtin");
    expect(record.name).toBe("create-pr");
    expect(record.artifactExpected).toBe("docs/reports/foreman-abc/PR_METADATA.json");
  });

  it("finalizes builtin phase with success status", () => {
    const record = createPhaseRecord("pr-wait", undefined, {
      phaseType: "builtin",
      artifactExpected: "docs/reports/foreman-abc/PR_WAIT_REPORT.md",
    });

    const finalized = finalizePhaseRecord(record, {
      success: true,
      costUsd: 0,
      turns: 0,
    });

    expect(finalized.phaseType).toBe("builtin");
    expect(finalized.success).toBe(true);
    expect(finalized.verdict).toBe("pass");
  });

  it("finalizes builtin phase with failure status", () => {
    const record = createPhaseRecord("pr-review", undefined, {
      phaseType: "builtin",
      artifactExpected: "docs/reports/foreman-abc/PR_REVIEW_REPORT.md",
    });

    const finalized = finalizePhaseRecord(record, {
      success: false,
      costUsd: 0,
      turns: 0,
      error: "PR review feedback: changes requested",
    });

    expect(finalized.phaseType).toBe("builtin");
    expect(finalized.success).toBe(false);
    expect(finalized.verdict).toBe("fail");
    expect(finalized.error).toBe("PR review feedback: changes requested");
  });
});
