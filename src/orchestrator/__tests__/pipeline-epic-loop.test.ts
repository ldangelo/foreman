/**
 * Integration tests for epic task loop in pipeline-executor (TRD-005-TEST).
 *
 * Verifies:
 *  1. 3 tasks execute in order, each commits
 *  2. QA FAIL retries developer, then passes
 *  3. QA FAIL exhausts retries — task fails, epic continues (onError=continue)
 *  4. Single-task mode unchanged (no epicTasks)
 *  5. Finalize runs once after all tasks
 *  6. No empty commits after task loop (VCS commit only on success)
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { EpicTask } from "../pipeline-executor.js";

// ── Helpers ───────────────────────────────────────────────────────────────

function makeEpicPipelineArgs(
  tmpDir: string,
  runPhase: ReturnType<typeof vi.fn>,
  log: ReturnType<typeof vi.fn>,
  epicTasks: EpicTask[],
  opts?: { onError?: string; vcsBackend?: unknown },
) {
  const mockStore = {
    updateRunProgress: vi.fn(),
    logEvent: vi.fn(),
  };

  const phases = [
    { name: "developer", prompt: "developer.md", artifact: "DEVELOPER_REPORT.md" },
    { name: "qa", prompt: "qa.md", artifact: "QA_REPORT.md", verdict: true, retryWith: "developer", retryOnFail: 2 },
    { name: "finalize", prompt: "finalize.md", artifact: "FINALIZE_VALIDATION.md" },
  ];

  return {
    config: {
      runId: "run-epic-001",
      projectId: "proj-001",
      seedId: "epic-001",
      seedTitle: "Epic test",
      model: "anthropic/claude-sonnet-4-6",
      worktreePath: tmpDir,
      env: {},
      vcsBackend: opts?.vcsBackend ?? undefined,
    },
    workflowConfig: {
      name: "epic",
      phases,
      taskPhases: ["developer", "qa"],
      finalPhases: ["finalize"],
      onError: opts?.onError ?? "continue",
    } as never,
    store: mockStore as never,
    logFile: join(tmpDir, "epic.log"),
    notifyClient: null,
    agentMailClient: null,
    epicTasks,
    runPhase,
    registerAgent: vi.fn().mockResolvedValue(undefined),
    sendMail: vi.fn(),
    sendMailText: vi.fn(),
    reserveFiles: vi.fn(),
    releaseFiles: vi.fn(),
    markStuck: vi.fn().mockResolvedValue(undefined),
    log,
    promptOpts: { projectRoot: tmpDir, workflow: "epic" },
  };
}

function successResult() {
  return { success: true, costUsd: 0.01, turns: 5, tokensIn: 100, tokensOut: 50 };
}

function qaPassReport(note = "All good."): string {
  return `# QA\n\n## Command\nnpm test -- --reporter=dot 2>&1\n\n## Raw Summary\n12 passed, 0 failed\n\n## Verdict: PASS\n${note}\n`;
}

function qaFailReport(note = "Test broken."): string {
  return `# QA\n\n## Command\nnpm test -- --reporter=dot 2>&1\n\n## Raw Summary\n10 passed, 2 failed\n\n## Verdict: FAIL\n${note}\n`;
}

function makeEpicTasks(count: number): EpicTask[] {
  return Array.from({ length: count }, (_, i) => ({
    seedId: `task-${i + 1}`,
    seedTitle: `Task ${i + 1}`,
    seedDescription: `Description for task ${i + 1}`,
  }));
}

// ── Tests ─────────────────────────────────────────────────────────────────

describe("epic task loop (TRD-005)", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-epic-test-"));
    mkdirSync(tmpDir, { recursive: true });
    // Create stub prompt files
    const promptDir = join(tmpDir, ".foreman", "prompts", "epic");
    mkdirSync(promptDir, { recursive: true });
    for (const phase of ["developer", "qa", "finalize"]) {
      writeFileSync(join(promptDir, `${phase}.md`), `# ${phase} stub\n`);
    }
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("3 tasks execute in order, each with developer→QA", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport("All good."));
      }
      return successResult();
    });

    const epicTasks = makeEpicTasks(3);
    await executePipeline(makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks) as never);

    // Each task: developer, qa. Then finalize once.
    expect(phaseOrder).toEqual([
      "developer", "qa",   // task 1
      "developer", "qa",   // task 2
      "developer", "qa",   // task 3
      "finalize",          // final phase
    ]);
  });

  it("QA FAIL retries developer, then passes", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();
    let qaCallCount = 0;

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        qaCallCount++;
        if (qaCallCount === 1) {
          // First QA: FAIL
          writeFileSync(join(tmpDir, "QA_REPORT.md"), qaFailReport("Test broken."));
        } else {
          // Subsequent QA: PASS
          writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport("Fixed."));
        }
      }
      return successResult();
    });

    const epicTasks = makeEpicTasks(1);
    await executePipeline(makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks) as never);

    // developer → qa (FAIL) → developer (retry) → qa (PASS) → finalize
    expect(phaseOrder).toEqual(["developer", "qa", "developer", "qa", "finalize"]);
    expect(log).toHaveBeenCalledWith(expect.stringContaining("FAIL"));
  });

  it("QA FAIL exhausts retries — task fails, epic continues to next task", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();
    let qaCallCount = 0;

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        qaCallCount++;
        if (qaCallCount <= 3) {
          // First task QA always FAILs (retryOnFail=2, so 3 attempts)
          writeFileSync(join(tmpDir, "QA_REPORT.md"), qaFailReport("Still broken."));
        } else {
          // Second task QA passes
          writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport("Fixed."));
        }
      }
      return successResult();
    });

    // Two tasks — first exhausts retries, second should pass
    const epicTasks = makeEpicTasks(2);
    await executePipeline(makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks) as never);

    // Task 1: developer → qa (FAIL) → developer → qa (FAIL) → developer → qa (FAIL) — exhausted
    // Task 2: developer → qa (PASS)
    // Then: finalize (since completedCount > 0)
    const devCount = phaseOrder.filter((p) => p === "developer").length;
    const qaCount = phaseOrder.filter((p) => p === "qa").length;
    expect(devCount).toBeGreaterThanOrEqual(4);
    expect(qaCount).toBeGreaterThanOrEqual(4);
    expect(phaseOrder[phaseOrder.length - 1]).toBe("finalize");
    expect(log).toHaveBeenCalledWith(expect.stringContaining("FAILED"));
  });

  it("single-task mode unchanged (no epicTasks)", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport());
      }
      return successResult();
    });

    // No epicTasks — should run all phases once (standard mode)
    const args = makeEpicPipelineArgs(tmpDir, runPhase, log, []);
    // Remove epicTasks to simulate single-task mode
    delete (args as Record<string, unknown>).epicTasks;
    await executePipeline(args as never);

    // Standard flow: developer → qa → finalize
    expect(phaseOrder).toEqual(["developer", "qa", "finalize"]);
  });

  it("groupedTasks alias runs the grouped-parent loop without legacy epic fields", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport());
      }
      return successResult();
    });

    const args = makeEpicPipelineArgs(tmpDir, runPhase, log, []);
    const groupedArgs = args as Record<string, any>;
    groupedArgs.groupedTasks = makeEpicTasks(2);
    groupedArgs.config.groupedParentId = "story-1";
    groupedArgs.config.groupedParentType = "story";
    delete groupedArgs.epicTasks;
    await executePipeline(groupedArgs as never);

    expect(phaseOrder).toEqual([
      "developer", "qa",
      "developer", "qa",
      "finalize",
    ]);
    expect(log).toHaveBeenCalledWith(expect.stringContaining("[STORY] Starting grouped pipeline"));
  });

  it("finalize runs once after all tasks", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport());
      }
      return successResult();
    });

    const epicTasks = makeEpicTasks(5);
    await executePipeline(makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks) as never);

    const finalizeCount = phaseOrder.filter((p) => p === "finalize").length;
    expect(finalizeCount).toBe(1);
    expect(phaseOrder[phaseOrder.length - 1]).toBe("finalize");
  });

  it("VCS commit is called after each successful task", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const log = vi.fn();
    const commitFn = vi.fn().mockResolvedValue(undefined);

    const mockVcsBackend = {
      name: "git",
      commit: commitFn,
      getFinalizeCommands: vi.fn().mockReturnValue({
        stageCommand: "git add -A",
        commitCommand: "git commit",
        pushCommand: "git push",
        integrateTargetCommand: "git rebase",
        branchVerifyCommand: "git branch",
        cleanCommand: "git clean",
        restoreTrackedStateCommand: "git restore --source=HEAD --staged --worktree -- .beads/issues.jsonl",
      }),
    };

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport());
      }
      return successResult();
    });

    const epicTasks = makeEpicTasks(3);
    await executePipeline(
      makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks, { vcsBackend: mockVcsBackend }) as never,
    );

    // 3 tasks → 3 commits
    expect(commitFn).toHaveBeenCalledTimes(3);
    expect(commitFn).toHaveBeenCalledWith(tmpDir, expect.stringContaining("task-1"));
    expect(commitFn).toHaveBeenCalledWith(tmpDir, expect.stringContaining("task-2"));
    expect(commitFn).toHaveBeenCalledWith(tmpDir, expect.stringContaining("task-3"));
  });

  it("onError=stop halts epic on task failure", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const phaseOrder: string[] = [];
    const log = vi.fn();
    const markStuck = vi.fn().mockResolvedValue(undefined);

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaFailReport("Broken."));
      }
      return successResult();
    });

    const epicTasks = makeEpicTasks(2);
    const args = makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks, { onError: "stop" });
    args.markStuck = markStuck;
    await executePipeline(args as never);

    // Should stop after first task fails (retries exhausted)
    expect(markStuck).toHaveBeenCalled();
    expect(log).toHaveBeenCalledWith(expect.stringContaining("onError=stop"));
    // Second task should not execute — no finalize either
    expect(phaseOrder[phaseOrder.length - 1]).not.toBe("finalize");
  });

  it("onPipelineComplete callback receives accumulated progress", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");
    const log = vi.fn();
    const onComplete = vi.fn().mockResolvedValue(undefined);

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport());
      }
      return successResult();
    });

    const epicTasks = makeEpicTasks(2);
    const args = makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks);
    (args as Record<string, unknown>).onPipelineComplete = onComplete;
    await executePipeline(args as never);

    expect(onComplete).toHaveBeenCalledTimes(1);
    const callArg = onComplete.mock.calls[0][0];
    // 2 tasks × 2 phases + 1 finalize = 5 phases total
    expect(callArg.progress.costUsd).toBeGreaterThan(0);
    expect(callArg.phaseRecords.length).toBe(5);
  });
});
