/**
 * Tests for epic resume detection (TRD-009).
 *
 * Verifies:
 *  1. parseCompletedTaskIds extracts bead IDs from git log output
 *  2. Resume skips tasks with existing commits
 *  3. Partial task (no commit) restarts from beginning
 *  4. Resume with 0 completed tasks starts from task 1
 *
 * Note: test setup uses execSync with hardcoded git commands to create
 * real git repos. No user input is involved — shell injection is not
 * a concern in test fixtures.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
// eslint-disable-next-line @typescript-eslint/no-require-imports
import { execSync } from "node:child_process";
import { parseCompletedTaskIds } from "../pipeline-executor.js";
import type { EpicTask } from "../pipeline-executor.js";

// ── Helpers ───────────────────────────────────────────────────────────────

function makeEpicPipelineArgs(
  tmpDir: string,
  runPhase: ReturnType<typeof vi.fn>,
  log: ReturnType<typeof vi.fn>,
  epicTasks: EpicTask[],
  opts?: { vcsBackend?: unknown },
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
      runId: "run-resume-001",
      projectId: "proj-001",
      seedId: "epic-001",
      seedTitle: "Epic resume test",
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
      onError: "continue",
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

function makeEpicTasks(count: number): EpicTask[] {
  return Array.from({ length: count }, (_, i) => ({
    seedId: `task-${i + 1}`,
    seedTitle: `Task ${i + 1}`,
    seedDescription: `Description for task ${i + 1}`,
  }));
}

/**
 * Initialize a real git repo in tmpDir with commits for the given task IDs.
 * This simulates a worktree that has already completed some tasks.
 *
 * Uses hardcoded git commands (no user input) for test fixtures only.
 */
function initGitWithCommits(dir: string, taskIds: string[]): void {
  execSync("git init", { cwd: dir, stdio: "ignore" });
  execSync("git config user.email test@test.com", { cwd: dir, stdio: "ignore" });
  execSync("git config user.name Test", { cwd: dir, stdio: "ignore" });

  // Initial commit so there's a HEAD
  writeFileSync(join(dir, "init.txt"), "init");
  execSync("git add -A && git commit -m 'initial'", { cwd: dir, stdio: "ignore" });

  for (const taskId of taskIds) {
    writeFileSync(join(dir, `${taskId}.txt`), taskId);
    execSync(`git add -A && git commit -m "Implement feature (${taskId})"`, {
      cwd: dir,
      stdio: "ignore",
    });
  }
}

// ── Unit tests for parseCompletedTaskIds ────────────────────────────────

describe("parseCompletedTaskIds", () => {
  it("extracts bead IDs from git log --oneline output", () => {
    const gitLog = [
      "abc1234 Implement feature (task-3)",
      "def5678 Add user auth (task-2)",
      "ghi9012 Setup database (task-1)",
      "jkl3456 initial commit",
    ].join("\n");

    const result = parseCompletedTaskIds(gitLog);
    expect(result).toEqual(new Set(["task-3", "task-2", "task-1"]));
  });

  it("returns empty set for empty log", () => {
    expect(parseCompletedTaskIds("")).toEqual(new Set());
  });

  it("returns empty set when no commit messages match pattern", () => {
    const gitLog = [
      "abc1234 initial commit",
      "def5678 merge branch dev",
    ].join("\n");

    const result = parseCompletedTaskIds(gitLog);
    expect(result).toEqual(new Set());
  });

  it("handles mixed matching and non-matching lines", () => {
    const gitLog = [
      "abc1234 Task 15 done (task-15)",
      "def5678 merge branch",
      "ghi9012 Task 10 done (task-10)",
      "",
      "jkl3456 random commit",
    ].join("\n");

    const result = parseCompletedTaskIds(gitLog);
    expect(result).toEqual(new Set(["task-15", "task-10"]));
  });

  it("handles bead IDs with various formats", () => {
    const gitLog = [
      "aaa1111 Fix bug (BUG-123)",
      "bbb2222 Add feature (feat/user-auth)",
      "ccc3333 Update docs (DOCS-42)",
    ].join("\n");

    const result = parseCompletedTaskIds(gitLog);
    expect(result).toEqual(new Set(["BUG-123", "feat/user-auth", "DOCS-42"]));
  });
});

// ── Integration tests for epic resume ───────────────────────────────────

describe("epic resume detection (TRD-009)", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-epic-resume-"));
    mkdirSync(tmpDir, { recursive: true });
    // Create stub prompt files
    const promptDir = join(tmpDir, ".foreman", "prompts", "epic");
    mkdirSync(promptDir, { recursive: true });
    for (const phase of ["developer", "qa", "finalize"]) {
      writeFileSync(join(promptDir, `${phase}.md`), `# ${phase} stub\n`);
    }
  });

  afterEach(() => {
    try {
      rmSync(tmpDir, { recursive: true, force: true });
    } catch {
      // Ignore cleanup errors (git index.lock race on macOS)
    }
  });

  it("resume skips tasks with existing commits", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    // Pre-create git repo with commits for tasks 1-3 (out of 5)
    initGitWithCommits(tmpDir, ["task-1", "task-2", "task-3"]);

    const phaseOrder: string[] = [];
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport("All good."));
      }
      return successResult();
    });

    const mockVcsBackend = {
      name: "git" as const,
      commit: vi.fn().mockResolvedValue(undefined),
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

    const epicTasks = makeEpicTasks(5);
    await executePipeline(
      makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks, { vcsBackend: mockVcsBackend }) as never,
    );

    // Only tasks 4 and 5 should have been executed (developer + qa each)
    // Plus finalize once at the end
    expect(phaseOrder).toEqual([
      "developer", "qa",   // task 4
      "developer", "qa",   // task 5
      "finalize",
    ]);

    // Verify resume log message
    expect(log).toHaveBeenCalledWith(
      expect.stringContaining("Resuming from task 4 of 5 (3 completed)"),
    );
  });

  it("partial task (no commit) restarts from beginning of task phases", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    // Pre-create git repo with commits for tasks 1-2 only
    // Task 3 was partially done (developer ran, but no QA -> no commit)
    initGitWithCommits(tmpDir, ["task-1", "task-2"]);

    const phaseOrder: string[] = [];
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport());
      }
      return successResult();
    });

    const epicTasks = makeEpicTasks(4);
    await executePipeline(makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks) as never);

    // Tasks 3 and 4 should run from scratch (developer + qa)
    // Task 3 restarts from developer (not just QA) since it has no commit
    expect(phaseOrder).toEqual([
      "developer", "qa",   // task 3 (restarted fully)
      "developer", "qa",   // task 4
      "finalize",
    ]);

    expect(log).toHaveBeenCalledWith(
      expect.stringContaining("Resuming from task 3 of 4 (2 completed)"),
    );
  });

  it("resume with 0 completed tasks starts from task 1", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    // Initialize git repo with no task commits (only initial)
    execSync("git init", { cwd: tmpDir, stdio: "ignore" });
    execSync("git config user.email test@test.com", { cwd: tmpDir, stdio: "ignore" });
    execSync("git config user.name Test", { cwd: tmpDir, stdio: "ignore" });
    writeFileSync(join(tmpDir, "init.txt"), "init");
    execSync("git add -A && git commit -m 'initial'", { cwd: tmpDir, stdio: "ignore" });

    const phaseOrder: string[] = [];
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport());
      }
      return successResult();
    });

    const epicTasks = makeEpicTasks(3);
    await executePipeline(makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks) as never);

    // All 3 tasks should run
    expect(phaseOrder).toEqual([
      "developer", "qa",   // task 1
      "developer", "qa",   // task 2
      "developer", "qa",   // task 3
      "finalize",
    ]);

    // Should NOT log a resume message
    const logCalls = log.mock.calls.map((c: unknown[]) => c[0] as string);
    expect(logCalls.some((msg: string) => msg.includes("Resuming"))).toBe(false);
  });

  it("no git repo at all starts from task 1 without error", async () => {
    const { executePipeline } = await import("../pipeline-executor.js");

    // tmpDir has no .git - detectCompletedTasks should return empty set
    const phaseOrder: string[] = [];
    const log = vi.fn();

    const runPhase = vi.fn().mockImplementation(async (phaseName: string) => {
      phaseOrder.push(phaseName);
      if (phaseName === "qa") {
        writeFileSync(join(tmpDir, "QA_REPORT.md"), qaPassReport());
      }
      return successResult();
    });

    const epicTasks = makeEpicTasks(2);
    await executePipeline(makeEpicPipelineArgs(tmpDir, runPhase, log, epicTasks) as never);

    // All tasks should run normally
    expect(phaseOrder).toEqual([
      "developer", "qa",
      "developer", "qa",
      "finalize",
    ]);
  });
});
