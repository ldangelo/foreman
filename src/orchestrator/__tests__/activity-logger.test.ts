import { describe, it, expect, vi } from "vitest";
import { mkdir, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";

import {
  createPhaseRecord,
  detectWarnings,
  finalizePhaseRecord,
  writeIncrementalPipelineReport,
  type PhaseRecord,
} from "../activity-logger.js";
import * as foremanPaths from "../../lib/foreman-paths.js";

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

  it("writeIncrementalPipelineReport includes builtin phases in the phase table", async () => {
    const reportsTmp = join(tmpdir(), `foreman-test-report-${Date.now()}-${Math.random()}`);
    await mkdir(reportsTmp, { recursive: true });

    // Spy on getForemanHomePath to return our temp directory
    const getForemanHomePathSpy = vi.spyOn(foremanPaths, "getForemanHomePath").mockImplementation((...segments) => {
      const parts = segments.join("/");
      if (parts.includes("reports/runs")) {
        // reports/runs/<runId>/<seedId> → reportsTmp/runs/<runId>/<seedId>
        const runsIdx = segments.indexOf("runs");
        return join(reportsTmp, ...segments.slice(runsIdx));
      }
      return join(reportsTmp, ...segments);
    });

    try {
      const builtinPhase: PhaseRecord = {
        name: "create-pr",
        phaseType: "builtin",
        skipped: false,
        success: true,
        costUsd: 0,
        turns: 0,
        toolCalls: 0,
        startedAt: new Date().toISOString(),
        completedAt: new Date().toISOString(),
        durationSeconds: 1.5,
        artifactExpected: undefined,
        artifactPresent: undefined,
      };
      const promptPhase: PhaseRecord = {
        name: "developer",
        phaseType: "prompt",
        skipped: false,
        success: true,
        costUsd: 0.003,
        turns: 4,
        toolCalls: 12,
        startedAt: new Date().toISOString(),
        completedAt: new Date().toISOString(),
        durationSeconds: 30,
        artifactExpected: "DEVELOPER_REPORT.md",
        artifactPresent: true,
        commandsRun: ["Build prompt..."],
      };

      await writeIncrementalPipelineReport({
        worktreePath: "/Users/test/.foreman/worktrees/test",
        seedId: "foreman-test-001",
        runId: "run-001",
        completedPhases: [builtinPhase, promptPhase],
        targetBranch: "main",
      });

      const reportPath = join(reportsTmp, "runs", "run-001", "foreman-test-001", "PIPELINE_REPORT.md");
      const report = await readFile(reportPath, "utf-8");

      // Builtin phase must appear in the Phase Results table
      expect(report).toContain("`create-pr`");
      expect(report).toContain("builtin");
      // Prompt phase must also appear
      expect(report).toContain("`developer`");
      expect(report).toContain("prompt");
    } finally {
      getForemanHomePathSpy.mockRestore();
      await rm(reportsTmp, { recursive: true, force: true });
    }
  });
});
