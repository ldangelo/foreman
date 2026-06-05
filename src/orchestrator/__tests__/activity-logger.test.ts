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

  it("writeIncrementalPipelineReport includes builtin phases in phase table", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-activity-"));
    const phases: import("../activity-logger.js").PhaseRecord[] = [
      createPhaseRecord("explorer", "MiniMax", {
        phaseType: "prompt",
        artifactExpected: "EXPLORER_REPORT.md",
      }),
      createPhaseRecord("developer", "MiniMax", {
        phaseType: "prompt",
        artifactExpected: "DEVELOPER_REPORT.md",
      }),
      createPhaseRecord("create-pr", undefined, {
        phaseType: "builtin",
        artifactExpected: "PR_URL.txt",
      }),
    ];

    const finalized = phases.map((phase, i) =>
      finalizePhaseRecord(phase, {
        success: i < 3,
        costUsd: 0.05,
        turns: 2,
      }),
    );

    await writeIncrementalPipelineReport({
      worktreePath,
      seedId: "foreman-test",
      runId: "run-test",
      completedPhases: finalized,
      targetBranch: "main",
    });

    const reportPath = join(worktreePath, "docs", "reports", "foreman-test", "PIPELINE_REPORT.md");
    const report = await readFile(reportPath, "utf-8");

    // All three phases must appear in the table including the builtin
    expect(report).toContain("`explorer`");
    expect(report).toContain("`developer`");
    expect(report).toContain("`create-pr`");
    // builtin type should be visible in the table
    expect(report).toMatch(/\| `create-pr` \| builtin \|/);
  });

  it("writeIncrementalPipelineReport records artifact present/missing status for builtin phases", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-activity-"));
    const phases: import("../activity-logger.js").PhaseRecord[] = [
      createPhaseRecord("pr-wait", undefined, {
        phaseType: "builtin",
        artifactExpected: "PR_WAIT_REPORT.md",
      }),
    ];

    const finalized = phases.map((phase) =>
      finalizePhaseRecord(phase, {
        success: true,
        costUsd: 0,
        turns: 0,
        // artifact is missing since we didn't write it
      }),
    );
    // Manually mark artifact as missing since no file was written
    finalized[0].artifactPresent = false;

    await writeIncrementalPipelineReport({
      worktreePath,
      seedId: "foreman-test",
      runId: "run-test",
      completedPhases: finalized,
      targetBranch: "main",
    });

    const reportPath = join(worktreePath, "docs", "reports", "foreman-test", "PIPELINE_REPORT.md");
    const report = await readFile(reportPath, "utf-8");

    // The phase row should show the artifact status
    expect(report).toContain("PR_WAIT_REPORT.md");
    expect(report).toMatch(/PR_WAIT_REPORT\.md \(missing\)/);
  });
});
