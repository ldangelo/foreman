import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { createPhaseTrace, finalizePhaseTrace, getForbiddenVcsAction } from "../pi-observability-extension.js";
import { writePhaseTrace } from "../pi-observability-writer.js";
import { writeIncrementalPipelineReport } from "../activity-logger.js";
import { createPhaseRecord, finalizePhaseRecord } from "../activity-logger.js";

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
      workflowName: "bug",
      workflowPath: "/tmp/project/.foreman/workflows/bug.yaml",
    });

    finalizePhaseTrace(trace, {
      success: true,
      finalMessage: "Fixed inbox rendering and added tests.",
    });

    expect(trace.expectedSkill).toBe("ensemble-fix-issue");
    expect(trace.commandLooksLikeLegacySlash).toBe(true);
    expect(trace.workflowPath).toBe("/tmp/project/.foreman/workflows/bug.yaml");
    expect(trace.artifactPresent).toBe(false);
    expect(trace.commandHonored).toBe(false);
    expect(trace.warnings).toContain("Expected artifact missing: DEVELOPER_REPORT.md");
  });

  it("blocks git commit and git push outside finalize", () => {
    expect(getForbiddenVcsAction("git commit -m 'x'", "fix")).toBe("git commit");
    expect(getForbiddenVcsAction("npm test && git push origin head", "test")).toBe("git push");
    expect(getForbiddenVcsAction("git commit -m 'x'", "finalize")).toBeUndefined();
    expect(getForbiddenVcsAction("git commit -m 'x'", "pr-review")).toBe("git commit");
    expect(getForbiddenVcsAction("git push", "finalize")).toBeUndefined();
    expect(getForbiddenVcsAction("git push", "pr-review")).toBe("git push");
    expect(getForbiddenVcsAction("git status", "fix")).toBeUndefined();
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

  it("sanitizes host-specific worktree paths in trace artifacts", async () => {
    // Use a path that looks like a real host-specific worktree path
    const worktreePath = "/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-e59b5";
    const trace = createPhaseTrace({
      runId: "run-sanitize",
      seedId: "foreman-sanitize",
      phase: "developer",
      phaseType: "prompt",
      model: "minimax/MiniMax-M2.7",
      worktreePath,
      rawPrompt: "cd /Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-e59b5 && npm test",
      resolvedCommand: "npm test",
      expectedArtifact: "DEVELOPER_REPORT.md",
    });

    // Add a tool call with args that contain the worktree path
    trace.toolCalls.push({
      toolCallId: "tool-001",
      toolName: "bash",
      startedAt: new Date().toISOString(),
      argsPreview: "cd /Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-e59b5 && npm test",
      resultPreview: "Test results at /Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-e59b5/coverage/lcov.info",
      updateCount: 0,
    });

    finalizePhaseTrace(trace, { success: true, finalMessage: "Tests passed." });

    const paths = await writePhaseTrace(trace);
    const jsonContent = await readFile(paths.jsonPath, "utf-8");
    const markdownContent = await readFile(paths.markdownPath, "utf-8");

    // Verify the host-specific path does NOT appear in artifacts
    expect(jsonContent).not.toContain("/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-e59b5");
    expect(markdownContent).not.toContain("/Users/ldangelo/.foreman/worktrees/52ba0d80-913d-4880-871b-a81e308c34d4/foreman-e59b5");

    // Verify the placeholder IS used
    expect(jsonContent).toContain("<worktree>");
    expect(markdownContent).toContain("<worktree>");
  });

  it("pipeline report includes builtin PR workflow phases", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-activity-"));
    const seedId = "foreman-pr-report";

    const builtinPhases = [
      createPhaseRecord("create-pr", undefined, { phaseType: "builtin" }),
      createPhaseRecord("pr-wait", undefined, { phaseType: "builtin" }),
      createPhaseRecord("prepare-pr-review", undefined, { phaseType: "builtin" }),
      createPhaseRecord("pr-review", undefined, { phaseType: "builtin" }),
    ];

    const completedPhases = builtinPhases.map((phase, i) =>
      finalizePhaseRecord(phase, {
        success: true,
        costUsd: 0,
        turns: 0,
      }),
    );

    await writeIncrementalPipelineReport({
      worktreePath,
      seedId,
      runId: "run-pr-report",
      completedPhases,
    });

    const reportPath = join(worktreePath, "docs", "reports", seedId, "PIPELINE_REPORT.md");
    const reportContent = await readFile(reportPath, "utf-8");

    expect(reportContent).toContain("`create-pr`");
    expect(reportContent).toContain("`pr-wait`");
    expect(reportContent).toContain("`prepare-pr-review`");
    expect(reportContent).toContain("`pr-review`");
    // Verify they show as builtin type in the phase table
    expect(reportContent).toContain("builtin");
  });
});
