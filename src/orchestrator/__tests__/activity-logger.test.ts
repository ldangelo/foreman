import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, it, expect } from "vitest";

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

  it("writeIncrementalPipelineReport includes builtin PR workflow phases in phase table", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-pipeline-report-"));
    const seedId = "foreman-test-pr";

    const builtinPhase = finalizePhaseRecord(
      createPhaseRecord("create-pr", undefined, { phaseType: "builtin" }),
      {
        success: true,
        costUsd: 0,
        turns: 0,
        toolCalls: 0,
        toolBreakdown: {},
        workflowName: "pr-workflow",
        workflowPath: ".foreman/workflows/pr.yaml",
      },
    );

    const developerPhase = finalizePhaseRecord(
      createPhaseRecord("developer", "MiniMax", {
        phaseType: "prompt",
        artifactExpected: "DEVELOPER_REPORT.md",
      }),
      {
        success: true,
        costUsd: 0.05,
        turns: 5,
        toolCalls: 12,
        toolBreakdown: { Read: 5, Edit: 3, Write: 4 },
        workflowName: "pr-workflow",
        workflowPath: ".foreman/workflows/pr.yaml",
      },
    );

    await writeIncrementalPipelineReport({
      worktreePath,
      seedId,
      runId: "run-test-pr",
      completedPhases: [builtinPhase, developerPhase],
      targetBranch: "main",
      vcsBranchName: "foreman/test-pr",
    });

    const reportPath = join(worktreePath, "docs", "reports", seedId, "PIPELINE_REPORT.md");
    const report = await readFile(reportPath, "utf-8");

    // Builtin phase must appear in the phase table
    expect(report).toContain("`create-pr`");
    expect(report).toContain("builtin");

    // Developer phase must also appear
    expect(report).toContain("`developer`");
    expect(report).toContain("prompt");
  });
});
