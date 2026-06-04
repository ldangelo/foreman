import { describe, it, expect } from "vitest";
import { mkdtemp, readFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

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

  it("creates phase record with builtin phaseType for PR workflow phases", () => {
    const prPhase = createPhaseRecord("create-pr", "MiniMax", {
      phaseType: "builtin",
      artifactExpected: "docs/reports/foreman-e59b5/QA_REPORT.md",
    });

    expect(prPhase.phaseType).toBe("builtin");
    expect(prPhase.name).toBe("create-pr");
  });

  it("writeIncrementalPipelineReport includes builtin phases in phase table", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-activity-"));
    const seedId = "foreman-e59b5";
    const runId = "run-test-001";

    const phases = [
      {
        name: "explorer",
        phaseType: "prompt" as const,
        skipped: false,
        success: true,
        costUsd: 0.05,
        turns: 2,
        artifactExpected: "EXPLORER_REPORT.md",
        artifactPresent: true,
        traceFile: "docs/reports/foreman-e59b5/EXPLORER_TRACE.json",
      },
      {
        name: "create-pr",
        phaseType: "builtin" as const,
        skipped: false,
        success: true,
        costUsd: 0,
        turns: 0,
        artifactExpected: "docs/reports/foreman-e59b5/QA_REPORT.md",
        artifactPresent: false,
      },
    ];

    await writeIncrementalPipelineReport({
      worktreePath,
      seedId,
      runId,
      completedPhases: phases,
      targetBranch: "main",
      vcsBranchName: "feature/test",
    });

    const reportPath = join(worktreePath, "docs", "reports", seedId, "PIPELINE_REPORT.md");
    const report = await readFile(reportPath, "utf-8");

    // Verify both phases appear in the table
    expect(report).toContain("`explorer`");
    expect(report).toContain("`create-pr`");
    // Verify builtin phase type is shown
    expect(report).toContain("builtin");
  });
});
