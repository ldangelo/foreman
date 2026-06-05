import { mkdtemp, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { createPhaseTrace, finalizePhaseTrace, getForbiddenVcsAction } from "../pi-observability-extension.js";
import { writePhaseTrace } from "../pi-observability-writer.js";
import { sanitizeTracePaths } from "../pi-observability-types.js";

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

  it("sanitizes absolute worktree paths in trace JSON and markdown", async () => {
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-trace-"));
    const absoluteWorktreePath = join(worktreePath, "project");
    const absoluteWorkflowPath = join(absoluteWorktreePath, ".foreman", "workflows", "bug.yaml");

    const trace = createPhaseTrace({
      runId: "run-sanitize",
      seedId: "foreman-sanitize",
      phase: "implement",
      phaseType: "command",
      model: "minimax/MiniMax-M2.7",
      worktreePath: absoluteWorktreePath,
      rawPrompt: `Working in ${absoluteWorktreePath} on the bug fix`,
      resolvedCommand: `cd ${absoluteWorktreePath} && git status`,
      expectedArtifact: "DEVELOPER_REPORT.md",
      workflowName: "bug",
      workflowPath: absoluteWorkflowPath,
    });

    // Add a tool call with args that contain the absolute path
    trace.toolCalls.push({
      toolCallId: "call_test_1",
      toolName: "bash",
      startedAt: new Date().toISOString(),
      completedAt: new Date().toISOString(),
      argsPreview: `{"command":"cd ${absoluteWorktreePath} && git status"}`,
      resultPreview: `{"output":"On branch main\\nYour branch is up to date with 'origin/main'."}`,
      updateCount: 1,
    });

    finalizePhaseTrace(trace, { success: true, finalMessage: "Done." });

    const paths = await writePhaseTrace(trace);
    const jsonContent = await readFile(paths.jsonPath, "utf-8");
    const markdownContent = await readFile(paths.markdownPath, "utf-8");

    // Verify absolute paths are NOT in the output
    expect(jsonContent).not.toContain(absoluteWorktreePath);
    expect(markdownContent).not.toContain(absoluteWorktreePath);

    // Verify placeholder IS in the output
    expect(jsonContent).toContain("$WORKTREE");
    expect(markdownContent).toContain("$WORKTREE");

    // Verify the JSON trace has the sanitized worktreePath
    const json = JSON.parse(jsonContent) as { worktreePath: string; workflowPath?: string };
    expect(json.worktreePath).toBe("$WORKTREE");
    expect(json.workflowPath).toBe("$WORKTREE/.foreman/workflows/bug.yaml");

    // Verify tool call args/result are sanitized
    expect(jsonContent).toContain('"argsPreview"');
    expect(jsonContent).toContain("$WORKTREE");
  });

  it("sanitizeTracePaths function replaces worktreePath with placeholder", () => {
    const trace = createPhaseTrace({
      runId: "run-test",
      seedId: "foreman-test",
      phase: "explorer",
      phaseType: "prompt",
      model: "minimax/MiniMax-M2.7",
      worktreePath: "/Users/testuser/.foreman/worktrees/abc123/foreman-test",
      rawPrompt: "Explore the codebase",
    });

    trace.toolCalls.push({
      toolCallId: "call_x",
      toolName: "bash",
      startedAt: new Date().toISOString(),
      argsPreview: '{"command":"cd /Users/testuser/.foreman/worktrees/abc123/foreman-test && ls"}',
      updateCount: 0,
    });

    const sanitized = sanitizeTracePaths(trace);

    expect(sanitized.worktreePath).toBe("$WORKTREE");
    expect(sanitized.toolCalls[0].argsPreview).toBe('{"command":"cd $WORKTREE && ls"}');
    // Original trace should be unchanged
    expect(trace.worktreePath).toContain("/Users/testuser/.foreman/worktrees/");
  });
});
