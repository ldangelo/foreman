import { describe, it, expect } from "vitest";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

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

  it("includes builtin phases in pipeline report phase table", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-activity-"));

    // Create a builtin phase record (like create-pr phase)
    const builtinRecord = finalizePhaseRecord(
      createPhaseRecord("create-pr", "MiniMax", {
        phaseType: "builtin",
        commandsRun: ["gh pr create --title 'Fix bug'"],
      }),
      {
        success: true,
        costUsd: 0,
        turns: 0,
        toolCalls: 0,
        toolBreakdown: {},
      },
    );

    // Create a normal prompt phase record for comparison
    const promptRecord = finalizePhaseRecord(
      createPhaseRecord("developer", "MiniMax", {
        phaseType: "prompt",
      }),
      {
        success: true,
        costUsd: 0.05,
        turns: 5,
        toolCalls: 12,
        toolBreakdown: { read: 5, edit: 4, bash: 3 },
      },
    );

    await writeIncrementalPipelineReport({
      worktreePath,
      seedId: "foreman-test",
      runId: "run-123",
      completedPhases: [builtinRecord, promptRecord],
    });

    const reportContent = await readFile(
      join(worktreePath, "docs", "reports", "foreman-test", "PIPELINE_REPORT.md"),
      "utf-8",
    );

    // Verify builtin phase appears in the phase table
    expect(reportContent).toContain("| `create-pr` | builtin |");
    // Verify prompt phase also appears
    expect(reportContent).toContain("| `developer` | prompt |");
    // Verify both phases are listed
    expect(reportContent).toContain("Phases completed | 2");
  });

  it("builtin phase record has correct phaseType", () => {
    const record = createPhaseRecord("create-pr", undefined, {
      phaseType: "builtin",
    });

    expect(record.phaseType).toBe("builtin");
    expect(record.name).toBe("create-pr");
  });
});
