import { mkdtemp, writeFile, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { createPhaseTrace, finalizePhaseTrace, getForbiddenVcsAction } from "../pi-observability-extension.js";
import { writePhaseTrace, sanitizeTraceForCommit } from "../pi-observability-writer.js";

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

  it("sanitizes absolute worktreePath in committed JSON/Markdown traces", async () => {
    // Use a real writable temp directory for worktreePath so writePhaseTrace can create files
    const worktreePath = await mkdtemp(join(tmpdir(), "foreman-trace-"));
    // Create a trace with the real temp path - the sanitization replaces this with <worktree> in committed output
    const trace = createPhaseTrace({
      runId: "run-sanitize-test",
      seedId: "foreman-sanitize",
      phase: "developer",
      phaseType: "prompt",
      model: "minimax/MiniMax-M2.7",
      worktreePath,
      rawPrompt: "Implement the feature",
      expectedArtifact: "DEVELOPER_REPORT.md",
    });
    finalizePhaseTrace(trace, { success: true, finalMessage: "Implemented." });

    // Sanity check: original trace has the actual worktree path (internal use)
    expect(trace.worktreePath).toBe(worktreePath);

    const paths = await writePhaseTrace(trace);
    const json = JSON.parse(await readFile(paths.jsonPath, "utf-8")) as { worktreePath: string };
    const markdown = await readFile(paths.markdownPath, "utf-8");

    // Committed JSON trace must NOT contain the actual worktree path — it should be sanitized
    expect(json.worktreePath).toBe("<worktree>");
    expect(json.worktreePath).not.toContain("/Users");
    expect(json.worktreePath).not.toContain("foreman-trace-");

    // Markdown trace must also not contain the worktree path
    expect(markdown).not.toContain(worktreePath);
  });

  it("sanitizeTraceForCommit replaces any absolute path with placeholder", () => {
    // Test the sanitization function directly with a path that would leak host info
    const absolutePath = "/Users/someone/.foreman/worktrees/my-seed-123";
    const trace = createPhaseTrace({
      runId: "run-direct-test",
      seedId: "test-seed",
      phase: "developer",
      phaseType: "prompt",
      model: "minimax/MiniMax-M2.7",
      worktreePath: absolutePath,
      rawPrompt: "Do work",
    });

    const sanitized = sanitizeTraceForCommit(trace);

    // Original unchanged
    expect(trace.worktreePath).toBe(absolutePath);
    // Sanitized has placeholder
    expect(sanitized.worktreePath).toBe("<worktree>");
    // Placeholder doesn't contain host-specific info
    expect(sanitized.worktreePath).not.toContain("Users");
    expect(sanitized.worktreePath).not.toContain(".foreman");
    expect(sanitized.worktreePath).not.toContain("someone");
  });

  it("sanitizeTraceForCommit leaves original trace unmodified", () => {
    const worktreePath = "/Users/test/.foreman/worktrees/test-seed";
    const trace = createPhaseTrace({
      runId: "run-original-test",
      seedId: "test-seed",
      phase: "developer",
      phaseType: "prompt",
      model: "minimax/MiniMax-M2.7",
      worktreePath,
      rawPrompt: "Do work",
    });

    const sanitized = sanitizeTraceForCommit(trace);

    // Original must be unchanged
    expect(trace.worktreePath).toBe(worktreePath);
    // Sanitized must have placeholder
    expect(sanitized.worktreePath).toBe("<worktree>");
  });
});
