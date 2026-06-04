import { mkdtemp, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { createPhaseTrace, finalizePhaseTrace, getForbiddenVcsAction } from "../pi-observability-extension.js";
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

  it("sanitizes absolute worktree paths in tool call argsPreview", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-trace-"));
    const trace = createPhaseTrace({
      runId: "run-sanitize-1",
      seedId: "foreman-56b46",
      phase: "developer",
      phaseType: "prompt",
      model: "minimax/MiniMax-M2.7",
      worktreePath,
      rawPrompt: "Fix the bug",
    });

    // Simulate a tool call with an absolute path in args
    // The args contain a read tool call with the worktree path embedded
    const toolCallArgsWithPath = JSON.stringify({ path: join(worktreePath, "src", "index.ts") });
    trace.toolCalls.push({
      toolCallId: "tool-call-1",
      toolName: "read",
      startedAt: new Date().toISOString(),
      argsPreview: toolCallArgsWithPath, // already sanitized at capture time
      updateCount: 0,
    });

    const paths = await writePhaseTrace(trace);
    const json = JSON.parse(await readFile(paths.jsonPath, "utf-8")) as {
      toolCalls: Array<{ toolCallId: string; argsPreview?: string }>;
    };

    // The argsPreview should not contain the absolute worktree path
    const argsPreview = json.toolCalls[0]?.argsPreview ?? "";
    expect(argsPreview).not.toContain(worktreePath);
    // It should be replaced with the placeholder
    expect(argsPreview).toContain("<worktree>");
  });

  it("sanitizes worktreePath field in JSON trace output", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-trace-"));
    const trace = createPhaseTrace({
      runId: "run-sanitize-2",
      seedId: "foreman-56b46",
      phase: "developer",
      phaseType: "prompt",
      model: "minimax/MiniMax-M2.7",
      worktreePath,
      rawPrompt: "Fix the bug",
    });
    finalizePhaseTrace(trace, { success: true, finalMessage: "Done." });

    const paths = await writePhaseTrace(trace);
    const json = await readFile(paths.jsonPath, "utf-8");

    // The worktreePath should not appear as-is in the JSON
    expect(json).not.toContain(worktreePath);
    // It should be replaced with the placeholder
    expect(json).toContain("<worktree>");
  });
});
