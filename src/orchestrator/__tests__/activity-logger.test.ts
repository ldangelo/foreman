import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it, expect, beforeEach, afterEach } from "vitest";

import {
  createPhaseRecord,
  detectWarnings,
  finalizePhaseRecord,
  writeIncrementalPipelineReport,
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

  it("includes builtin phases in pipeline report with correct phase type", async () => {
    const tempDir = await mkdtemp(join(tmpdir(), "foreman-activity-logger-test-"));
    const originalForemanHome = process.env.FOREMAN_HOME;
    process.env.FOREMAN_HOME = tempDir;

    try {
      const explorerPhase = finalizePhaseRecord(
        createPhaseRecord("explorer", "MiniMax", {
          phaseType: "prompt",
          artifactExpected: "EXPLORER_REPORT.md",
        }),
        {
          success: true,
          costUsd: 0.05,
          turns: 5,
          toolCalls: 10,
        },
      );

      const developerPhase = finalizePhaseRecord(
        createPhaseRecord("developer", "MiniMax", {
          phaseType: "prompt",
          artifactExpected: "docs/reports/foreman-abc/DEVELOPER_REPORT.md",
        }),
        {
          success: true,
          costUsd: 0.50,
          turns: 20,
          toolCalls: 45,
        },
      );

      const createPrPhase = finalizePhaseRecord(
        createPhaseRecord("create-pr", undefined, {
          phaseType: "builtin",
          artifactExpected: "docs/reports/foreman-abc/PR_METADATA.json",
        }),
        {
          success: true,
          costUsd: 0,
          turns: 0,
        },
      );

      const prWaitPhase = finalizePhaseRecord(
        createPhaseRecord("pr-wait", undefined, {
          phaseType: "builtin",
          artifactExpected: "docs/reports/foreman-abc/PR_WAIT_REPORT.md",
        }),
        {
          success: true,
          costUsd: 0,
          turns: 0,
        },
      );

      await writeIncrementalPipelineReport({
        worktreePath: "/tmp/worktree",
        taskId: "foreman-abc",
        runId: "run-testBuiltin",
        completedPhases: [explorerPhase, developerPhase, createPrPhase, prWaitPhase],
        targetBranch: "main",
        vcsBranchName: "foreman/foreman-abc",
      });

      const reportPath = join(tempDir, "reports", "runs", "run-testBuiltin", "foreman-abc", "PIPELINE_REPORT.md");
      const report = await readFile(reportPath, "utf-8");

      // Verify builtin phases appear in the report with correct type
      expect(report).toContain("`create-pr`");
      expect(report).toContain("`pr-wait`");
      expect(report).toContain("| builtin |");
      expect(report).toContain("| prompt |");
      // Verify builtin phases show correct artifact paths
      expect(report).toContain("docs/reports/foreman-abc/PR_METADATA.json");
      expect(report).toContain("docs/reports/foreman-abc/PR_WAIT_REPORT.md");
    } finally {
      process.env.FOREMAN_HOME = originalForemanHome;
    }
  });
});
