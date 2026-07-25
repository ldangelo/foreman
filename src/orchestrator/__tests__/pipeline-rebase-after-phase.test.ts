/**
 * Regression tests for rebaseAfterPhase mid-pipeline rebase feature (PRD-2026-005).
 *
 * Verifies:
 *  1. rebaseAfterPhase absent → no rebase call (no-op)
 *  2. rebaseAfterPhase configured → vcsBackend.rebase called with correct target
 *  3. No vcsBackend → rebase skipped gracefully, pipeline continues
 *  4. Rebase conflict (success=false) → agent-error mail sent, pipeline fails
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

function successResult() {
  return { success: true, costUsd: 0.01, turns: 5, tokensIn: 100, tokensOut: 50 };
}

function makePipelineArgs(tmpDir: string, runPhase: ReturnType<typeof vi.fn>, log: ReturnType<typeof vi.fn>, vcsBackend?: unknown) {
  const mockStore = { updateRunProgress: vi.fn(), logEvent: vi.fn() };
  return {
    config: {
      runId: "run-rebase-001",
      projectId: "proj-001",
      taskId: "task-001",
      taskTitle: "Rebase test",
      model: "anthropic/claude-sonnet-4-6",
      worktreePath: tmpDir,
      env: {},
      vcsBackend: vcsBackend as never,
    },
    workflowConfig: {
      name: "rebase-test",
      phases: [
        { name: "developer", prompt: "developer.md", artifact: "DEVELOPER_REPORT.md" },
        { name: "qa", prompt: "qa.md", artifact: "QA_REPORT.md", verdict: true, retryWith: "developer", retryOnFail: 2 },
        { name: "finalize", prompt: "finalize.md", artifact: "FINALIZE_VALIDATION.md" },
      ],
    } as never,
    store: mockStore as never,
    logFile: join(tmpDir, "rebase.log"),
    notifyClient: null,
    agentMailClient: null,
    runPhase,
    registerAgent: vi.fn().mockResolvedValue(undefined),
    sendMail: vi.fn(),
    sendMailText: vi.fn(),
    reserveFiles: vi.fn(),
    releaseFiles: vi.fn(),
    markStuck: vi.fn().mockResolvedValue(undefined),
    log,
    promptOpts: { projectRoot: tmpDir, workflow: "rebase-test" },
  };
}

describe("rebaseAfterPhase regression (PRD-2026-005)", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-rebase-test-"));
    mkdirSync(tmpDir, { recursive: true });
    const promptDir = join(tmpDir, ".foreman", "prompts", "rebase-test");
    mkdirSync(promptDir, { recursive: true });
    for (const phase of ["developer", "qa", "finalize"]) {
      writeFileSync(join(promptDir, `${phase}.md`), `# ${phase} stub\n`);
    }
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("no rebaseAfterPhase → vcsBackend.rebase never called", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const log = vi.fn();
    const rebaseFn = vi.fn().mockResolvedValue({ success: true, hasConflicts: false });
    const vcsBackend = { name: "git", rebase: rebaseFn } as never;

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA\n\n## Verdict: PASS\n");
      }
      return successResult();
    });

    // Workflow has no rebaseAfterPhase on any phase
    const args = makePipelineArgs(tmpDir, runPhase, log, vcsBackend);
    await executePipeline(args as never);

    expect(rebaseFn).not.toHaveBeenCalled();
  });

  it("rebaseAfterPhase configured → vcsBackend.rebase called with correct target after phase", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const log = vi.fn();
    const rebaseFn = vi.fn().mockResolvedValue({ success: true, hasConflicts: false });
    const vcsBackend = { name: "git", rebase: rebaseFn } as never;

    const phaseOrder: string[] = [];
    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA\n\n## Verdict: PASS\n");
      }
      return successResult();
    });

    const args = makePipelineArgs(tmpDir, runPhase, log, vcsBackend);
    // Configure rebaseAfterPhase on developer phase → rebase fires after developer, before qa
    (args.workflowConfig as Record<string, unknown>).phases = [
      { name: "developer", prompt: "developer.md", artifact: "DEVELOPER_REPORT.md", rebaseAfterPhase: "origin/dev" },
      { name: "qa", prompt: "qa.md", artifact: "QA_REPORT.md", verdict: true, retryWith: "developer", retryOnFail: 2 },
      { name: "finalize", prompt: "finalize.md", artifact: "FINALIZE_VALIDATION.md" },
    ];
    await executePipeline(args as never);

    // rebase fires after developer completes, before qa starts
    expect(rebaseFn).toHaveBeenCalledTimes(1);
    expect(rebaseFn).toHaveBeenCalledWith(tmpDir, "origin/dev");
    // Phase order should still be developer → qa → finalize (rebase is internal to executor)
    expect(phaseOrder).toEqual(["developer", "qa", "finalize"]);
  });

  it("no vcsBackend → rebase skipped gracefully, no error thrown", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA\n\n## Verdict: PASS\n");
      }
      return successResult();
    });

    const args = makePipelineArgs(tmpDir, runPhase, log, undefined);
    (args.workflowConfig as Record<string, unknown>).phases = [
      { name: "developer", prompt: "developer.md", artifact: "DEVELOPER_REPORT.md", rebaseAfterPhase: "origin/dev" },
      { name: "qa", prompt: "qa.md", artifact: "QA_REPORT.md", verdict: true, retryWith: "developer", retryOnFail: 2 },
      { name: "finalize", prompt: "finalize.md", artifact: "FINALIZE_VALIDATION.md" },
    ];

    // Should not throw even though rebaseAfterPhase is set with no vcsBackend
    await expect(executePipeline(args as never)).resolves.not.toThrow();

    // Should have logged the ignored rebase
    expect(log).toHaveBeenCalledWith(expect.stringContaining("rebaseAfterPhase"));
    expect(log).toHaveBeenCalledWith(expect.stringContaining("ignored"));
  });

  it("rebase conflict (success=false) → agent-error mail sent", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const log = vi.fn();
    const rebaseFn = vi.fn().mockResolvedValue({ success: false, conflictingFiles: ["src/app.ts", "src/index.ts"] });
    const vcsBackend = { name: "git", rebase: rebaseFn } as never;

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), "# QA\n\n## Verdict: PASS\n");
      }
      return successResult();
    });

    const args = makePipelineArgs(tmpDir, runPhase, log, vcsBackend);
    (args.workflowConfig as Record<string, unknown>).phases = [
      { name: "developer", prompt: "developer.md", artifact: "DEVELOPER_REPORT.md", rebaseAfterPhase: "origin/dev" },
      { name: "qa", prompt: "qa.md", artifact: "QA_REPORT.md", verdict: true, retryWith: "developer", retryOnFail: 2 },
      { name: "finalize", prompt: "finalize.md", artifact: "FINALIZE_VALIDATION.md" },
    ];

    await executePipeline(args as never);

    // agent-error mail should have been sent with conflict details
    expect(args.sendMail).toHaveBeenCalledWith(
      expect.anything(),
      "foreman",
      "agent-error",
      expect.objectContaining({
        error: expect.stringContaining("Rebase onto origin/dev failed"),
        retryable: false,
      }),
    );
  });
});
