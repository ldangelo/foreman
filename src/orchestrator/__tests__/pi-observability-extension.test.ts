import { mkdtemp, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { createPhaseTrace, finalizePhaseTrace } from "../pi-observability-extension.js";
import { writePhaseTrace } from "../pi-observability-writer.js";

describe("pi observability trace", () => {
  it("detects legacy slash commands and flags missing artifact evidence", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-trace-"));
    const trace = createPhaseTrace({
      runId: "run-123",
      seedId: "foreman-56b46",
      phase: "fix",
      phaseType: "command",
      model: "minimax/MiniMax-M2.7",
      worktreePath,
      rawPrompt: "/ensemble:fix-issue Fix the broken inbox rendering",
      resolvedCommand: "/ensemble:fix-issue Fix the broken inbox rendering",
      expectedArtifact: "DEVELOPER_REPORT.md",
      systemPrompt: "You are the fix agent",
    });

    finalizePhaseTrace(trace, {
      success: true,
      finalMessage: "Fixed inbox rendering and added tests.",
    });

    expect(trace.expectedSkill).toBe("ensemble-fix-issue");
    expect(trace.commandLooksLikeLegacySlash).toBe(true);
    expect(trace.artifactPresent).toBe(false);
    expect(trace.commandHonored).toBe(false);
    expect(trace.warnings).toContain("Expected artifact missing: DEVELOPER_REPORT.md");
  });

  it("marks command intent as honored when the expected artifact exists", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-trace-"));
    await writeFile(join(worktreePath, "DEVELOPER_REPORT.md"), "# done\n", "utf-8");
    const trace = createPhaseTrace({
      runId: "run-456",
      seedId: "foreman-56b46",
      phase: "fix",
      phaseType: "command",
      model: "minimax/MiniMax-M2.7",
      worktreePath,
      rawPrompt: "/skill:ensemble-fix-issue Fix the broken inbox rendering",
      resolvedCommand: "/skill:ensemble-fix-issue Fix the broken inbox rendering",
      expectedArtifact: "DEVELOPER_REPORT.md",
      systemPrompt: "You are the fix agent",
    });

    finalizePhaseTrace(trace, {
      success: true,
      finalMessage: "Generated DEVELOPER_REPORT.md after fixing the issue.",
    });

    expect(trace.artifactPresent).toBe(true);
    expect(trace.commandHonored).toBe(true);
  });

  it("writes json and markdown trace artifacts under docs/reports/<seed>", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-trace-"));
    const trace = createPhaseTrace({
      runId: "run-789",
      seedId: "foreman-56b46",
      phase: "fix",
      phaseType: "command",
      model: "minimax/MiniMax-M2.7",
      worktreePath,
      rawPrompt: "/ensemble:fix-issue Fix the broken inbox rendering",
      resolvedCommand: "/ensemble:fix-issue Fix the broken inbox rendering",
      expectedArtifact: "DEVELOPER_REPORT.md",
    });
    finalizePhaseTrace(trace, { success: true, finalMessage: "Done." });

    const paths = await writePhaseTrace(trace);
    const json = JSON.parse(await readFile(paths.jsonPath, "utf-8")) as { phase: string; seedId: string };
    const markdown = await readFile(paths.markdownPath, "utf-8");

    expect(paths.relativeJsonPath).toBe("docs/reports/foreman-56b46/FIX_TRACE.json");
    expect(json.phase).toBe("fix");
    expect(json.seedId).toBe("foreman-56b46");
    expect(markdown).toContain("# FIX Trace — foreman-56b46");
    expect(markdown).toContain("DEVELOPER_REPORT.md");
  });
});
