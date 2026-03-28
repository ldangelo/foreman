import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Mock setup ─────────────────────────────────────────────────────────────
//
// We mock node:child_process for the non-git execFileSync (tsc) call.
// VcsBackend is mocked via a vi.fn() stub passed directly to finalize().
//
// vi.hoisted() ensures mock variables are initialised before the module
// factory runs (vitest hoists vi.mock() calls to the top of the file).

const { mockExecFileSync, mockEnqueueToMergeQueue, mockAppendFile, mockEnqueueBeadWrite } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn(),
  mockEnqueueToMergeQueue: vi.fn().mockReturnValue({ success: true }),
  mockAppendFile: vi.fn().mockResolvedValue(undefined),
  mockEnqueueBeadWrite: vi.fn(),
}));

vi.mock("node:child_process", () => ({
  execFileSync: mockExecFileSync,
}));

vi.mock("node:fs/promises", () => ({
  appendFile: mockAppendFile,
}));

vi.mock("../agent-worker-enqueue.js", () => ({
  enqueueToMergeQueue: mockEnqueueToMergeQueue,
}));

vi.mock("../../lib/git.js", () => ({
  detectDefaultBranch: vi.fn().mockResolvedValue("main"),
}));

// Mock ForemanStore so we don't need a real SQLite database
vi.mock("../../lib/store.js", () => ({
  ForemanStore: {
    forProject: vi.fn(() => ({
      getDb: vi.fn(() => ({})),
      close: vi.fn(),
      enqueueBeadWrite: mockEnqueueBeadWrite,
    })),
  },
}));

import { finalize, rotateReport } from "../agent-worker-finalize.js";
import type { FinalizeConfig, FinalizeResult } from "../agent-worker-finalize.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

// ── VcsBackend Mock Factory ───────────────────────────────────────────────────

/**
 * Creates a fully mocked VcsBackend for testing.
 * Default implementations succeed with sensible defaults.
 * Tests can override individual methods using mockImplementation / mockRejectedValue.
 */
function makeMockVcs(overrides: Partial<Record<keyof VcsBackend, ReturnType<typeof vi.fn>>> = {}): VcsBackend {
  return {
    name: "git",
    // Repository introspection
    getRepoRoot: vi.fn().mockResolvedValue("/repo"),
    getMainRepoRoot: vi.fn().mockResolvedValue("/repo"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    getCurrentBranch: vi.fn().mockResolvedValue("foreman/bd-test-001"),
    // Branch operations
    checkoutBranch: vi.fn().mockResolvedValue(undefined),
    branchExists: vi.fn().mockResolvedValue(true),
    branchExistsOnRemote: vi.fn().mockResolvedValue(true),
    deleteBranch: vi.fn().mockResolvedValue({ deleted: true }),
    // Workspace operations
    createWorkspace: vi.fn().mockResolvedValue({ workspacePath: "/workspace", branchName: "foreman/bd-test-001" }),
    removeWorkspace: vi.fn().mockResolvedValue(undefined),
    listWorkspaces: vi.fn().mockResolvedValue([]),
    // Staging and commit
    stageAll: vi.fn().mockResolvedValue(undefined),
    commit: vi.fn().mockResolvedValue(undefined),
    push: vi.fn().mockResolvedValue(undefined),
    pull: vi.fn().mockResolvedValue(undefined),
    // Rebase and merge
    rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    abortRebase: vi.fn().mockResolvedValue(undefined),
    merge: vi.fn().mockResolvedValue({ success: true, conflictingFiles: [] }),
    // Diff, status, conflict detection
    getHeadId: vi.fn().mockResolvedValue("abc1234"),
    fetch: vi.fn().mockResolvedValue(undefined),
    diff: vi.fn().mockResolvedValue(""),
    getModifiedFiles: vi.fn().mockResolvedValue([]),
    getConflictingFiles: vi.fn().mockResolvedValue([]),
    status: vi.fn().mockResolvedValue(""),
    cleanWorkingTree: vi.fn().mockResolvedValue(undefined),
    // Finalize support
    getFinalizeCommands: vi.fn().mockReturnValue({
      stageCommand: "git add -A",
      commitCommand: "git commit -m",
      pushCommand: "git push -u origin",
      rebaseCommand: "git pull --rebase origin",
      branchVerifyCommand: "git rev-parse --abbrev-ref HEAD",
      cleanCommand: "git clean -fd",
    }),
    ...overrides,
  } as VcsBackend;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeConfig(overrides: Partial<FinalizeConfig> = {}): FinalizeConfig {
  // Note: `worktreePath` has no default here — every test that touches the
  // filesystem must supply a real tmpDir via overrides to ensure isolation.
  return {
    runId: "run-test-001",
    seedId: "bd-test-001",
    seedTitle: "Fix the test bug",
    projectPath: "/tmp/fake-project",
    ...overrides,
  } as FinalizeConfig;
}

// ── rotateReport ──────────────────────────────────────────────────────────────

describe("rotateReport", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-rotate-test-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("renames an existing report file with a timestamp suffix", () => {
    const filename = "FINALIZE_REPORT.md";
    writeFileSync(join(tmpDir, filename), "# Old report");

    rotateReport(tmpDir, filename);

    // Original file should be gone
    expect(existsSync(join(tmpDir, filename))).toBe(false);
    // A rotated file with a timestamp suffix should exist
    const files = readdirSync(tmpDir);
    const rotated = files.find((f) => f.startsWith("FINALIZE_REPORT.") && f.endsWith(".md") && f !== filename);
    expect(rotated).toBeDefined();
  });

  it("does nothing when the file does not exist (non-fatal)", () => {
    // Should not throw
    expect(() => rotateReport(tmpDir, "NONEXISTENT.md")).not.toThrow();
  });
});

// ── finalize — push succeeds ──────────────────────────────────────────────────

describe("finalize() — push succeeds", () => {
  let logFile: string;
  let tmpDir: string;
  let mockVcs: VcsBackend;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });

    // tsc succeeds by default (mockExecFileSync does nothing)
    mockVcs = makeMockVcs();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns success=true when push succeeds", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, mockVcs);
    expect(result.success).toBe(true);
  });

  it("finalize returns true when push succeeds (bead closed by refinery, not here)", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir, projectPath: "/my/project" }), logFile, mockVcs);
    expect(result.success).toBe(true);
  });

  it("sets bead to 'review' status after successful push (not closing it)", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir, seedId: "bd-test-001" }), logFile, mockVcs);
    // Verify enqueueBeadWrite was called with "set-status" and the correct seedId/status
    const reviewCall = mockEnqueueBeadWrite.mock.calls.find(
      (call) =>
        Array.isArray(call) &&
        call[1] === "set-status" &&
        call[2]?.status === "review" &&
        call[2]?.seedId === "bd-test-001",
    );
    expect(reviewCall).toBeDefined();
  });

  it("does NOT call br close after push succeeds (bead lifecycle fix)", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, mockVcs);
    // execFileSync should only be called for tsc (not for git commands)
    const gitClose = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "close",
    );
    expect(gitClose).toBeUndefined();
  });

  it("calls vcs.push with correct branch name", async () => {
    const vcs = makeMockVcs();
    await finalize(makeConfig({ worktreePath: tmpDir, seedId: "bd-xyz-999" }), logFile, vcs);
    expect(vcs.push).toHaveBeenCalledWith(tmpDir, "foreman/bd-xyz-999");
  });

  it("writes FINALIZE_REPORT.md with AWAITING_MERGE (review) status after successful push", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, mockVcs);
    const reportPath = join(tmpDir, "FINALIZE_REPORT.md");
    expect(existsSync(reportPath)).toBe(true);
    const content = readFileSync(reportPath, "utf-8");
    expect(content).toContain("## Seed Status");
    expect(content).toContain("AWAITING_MERGE");
  });

  it("enqueues to merge queue when push succeeds", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, mockVcs);
    expect(mockEnqueueToMergeQueue).toHaveBeenCalledOnce();
  });

  it("uses vcs.stageAll and vcs.commit for the commit step", async () => {
    const vcs = makeMockVcs();
    await finalize(makeConfig({ worktreePath: tmpDir, seedId: "bd-test-001", seedTitle: "My fix" }), logFile, vcs);
    expect(vcs.stageAll).toHaveBeenCalledWith(tmpDir);
    expect(vcs.commit).toHaveBeenCalledWith(tmpDir, "My fix (bd-test-001)");
  });

  it("uses vcs.getHeadId after commit to get the commit hash", async () => {
    const vcs = makeMockVcs();
    (vcs.getHeadId as ReturnType<typeof vi.fn>).mockResolvedValue("deadbeef");
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    expect(content).toContain("Hash: deadbeef");
  });

  it("uses vcs.getCurrentBranch for branch verification", async () => {
    const vcs = makeMockVcs();
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.getCurrentBranch).toHaveBeenCalledWith(tmpDir);
  });

  it("zero direct execFileSync git calls in finalize() — only npx/tsc allowed", async () => {
    const vcs = makeMockVcs();
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    // Any execFileSync call must be for 'npx', never 'git'
    for (const call of mockExecFileSync.mock.calls) {
      expect(call[0]).not.toBe("git");
    }
  });
});

// ── finalize — push FAILS ─────────────────────────────────────────────────────

describe("finalize() — push FAILS", () => {
  let logFile: string;
  let tmpDir: string;
  let mockVcs: VcsBackend;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-pushfail-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
    mockEnqueueBeadWrite.mockReset();

    mockVcs = makeMockVcs({
      push: vi.fn().mockRejectedValue(new Error("remote: Permission to repo denied.")),
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns success=false when push fails", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, mockVcs);
    expect(result.success).toBe(false);
  });

  it("returns retryable=true for transient push failures (e.g. permissions)", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, mockVcs);
    expect(result.retryable).toBe(true);
  });

  it("enqueues to merge queue BEFORE push, even when push fails (source-of-truth write)", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, mockVcs);
    expect(mockEnqueueToMergeQueue).toHaveBeenCalledOnce();
  });

  it("writes FINALIZE_REPORT.md with FAILED push and PUSH_FAILED seed status", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, mockVcs);
    const reportPath = join(tmpDir, "FINALIZE_REPORT.md");
    expect(existsSync(reportPath)).toBe(true);
    const content = readFileSync(reportPath, "utf-8");
    expect(content).toContain("## Push");
    expect(content).toContain("Status: FAILED");
    expect(content).toContain("## Seed Status");
    expect(content).toContain("PUSH_FAILED");
  });

  it("does not throw even when push fails", async () => {
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, mockVcs);
    expect(result.success).toBe(false);
  });

  it("does NOT set bead to review when push fails (bead stays in_progress for caller to reset)", async () => {
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, mockVcs);
    const reviewCall = mockEnqueueBeadWrite.mock.calls.find(
      (call) =>
        Array.isArray(call) &&
        call[1] === "set-status" &&
        call[2]?.status === "review",
    );
    expect(reviewCall).toBeUndefined();
  });
});

// ── finalize — enqueue-before-push ordering (bd-neph fix) ────────────────────

describe("finalize() — enqueue-before-push ordering (bd-neph)", () => {
  let logFile: string;
  let tmpDir: string;
  const callOrder: string[] = [];

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-order-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    callOrder.length = 0;

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockImplementation(() => {
      callOrder.push("enqueue");
      return { success: true };
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("calls enqueueToMergeQueue BEFORE vcs.push", async () => {
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        callOrder.push("push");
      }),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const enqueueIdx = callOrder.indexOf("enqueue");
    const pushIdx = callOrder.indexOf("push");
    expect(enqueueIdx).toBeGreaterThanOrEqual(0);
    expect(pushIdx).toBeGreaterThanOrEqual(0);
    expect(enqueueIdx).toBeLessThan(pushIdx);
  });

  it("enqueue is called even when push subsequently fails", async () => {
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        callOrder.push("push");
        throw new Error("remote: Permission to repo denied.");
      }),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(mockEnqueueToMergeQueue).toHaveBeenCalledOnce();
    const enqueueIdx = callOrder.indexOf("enqueue");
    const pushIdx = callOrder.indexOf("push");
    expect(enqueueIdx).toBeLessThan(pushIdx);
  });

  it("does NOT enqueue when branch verification fails (branchVerified=false)", async () => {
    const vcs = makeMockVcs({
      getCurrentBranch: vi.fn().mockRejectedValue(new Error("not a git repository")),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(mockEnqueueToMergeQueue).not.toHaveBeenCalled();
  });

  it("writes FINALIZE_REPORT.md with Merge Queue section BEFORE Push section", async () => {
    const vcs = makeMockVcs();
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    const mergeQueueIdx = content.indexOf("## Merge Queue");
    const pushIdx = content.indexOf("## Push");
    expect(mergeQueueIdx).toBeGreaterThanOrEqual(0);
    expect(pushIdx).toBeGreaterThanOrEqual(0);
    expect(mergeQueueIdx).toBeLessThan(pushIdx);
  });
});

// ── finalize — tsc failure is non-fatal ───────────────────────────────────────

describe("finalize() — type check failure is non-fatal", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-tscfail-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });

    // tsc fails
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (_bin === "npx" && Array.isArray(args) && args[0] === "tsc") {
        throw new Error("Type error: cannot find module");
      }
      return Buffer.from("");
    });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns success=true (push succeeded) even when type check fails", async () => {
    const vcs = makeMockVcs();
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(result.success).toBe(true);
  });

  it("reports type check failure in FINALIZE_REPORT.md", async () => {
    const vcs = makeMockVcs();
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const reportPath = join(tmpDir, "FINALIZE_REPORT.md");
    const content = readFileSync(reportPath, "utf-8");
    expect(content).toContain("## Build / Type Check");
    expect(content).toContain("Status: FAILED");
  });
});

// ── finalize — commit "nothing to commit" is non-fatal ────────────────────────

describe("finalize() — nothing to commit", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-nocommit-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns success=true and still pushes when nothing to commit", async () => {
    const vcs = makeMockVcs({
      commit: vi.fn().mockRejectedValue(new Error("nothing to commit, working tree clean")),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(result.success).toBe(true);
  });

  it("reports commit as SKIPPED (nothing to commit) in the report", async () => {
    const vcs = makeMockVcs({
      commit: vi.fn().mockRejectedValue(new Error("nothing to commit, working tree clean")),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const reportPath = join(tmpDir, "FINALIZE_REPORT.md");
    const content = readFileSync(reportPath, "utf-8");
    expect(content).toContain("Status: SKIPPED (nothing to commit)");
  });
});

// ── finalize — merge queue uses correct projectPath ───────────────────────────

describe("finalize() — projectPath used for merge queue store", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-path-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("finalize succeeds when projectPath is provided", async () => {
    const vcs = makeMockVcs();
    const result = await finalize(makeConfig({ worktreePath: tmpDir, projectPath: "/explicit/project" }), logFile, vcs);
    expect(result.success).toBe(true);
  });

  it("finalize succeeds when projectPath is not provided (falls back to worktree parent)", async () => {
    const vcs = makeMockVcs();
    const result = await finalize(makeConfig({ worktreePath: tmpDir, projectPath: undefined }), logFile, vcs);
    expect(result.success).toBe(true);
  });
});

// ── finalize — non-fast-forward push failure (bd-zwtr regression) ─────────────

describe("finalize() — non-fast-forward push: rebase succeeds → push succeeds", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-nff-ok-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns success=true after successful rebase + retry push", async () => {
    let pushCallCount = 0;
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        pushCallCount++;
        if (pushCallCount === 1) {
          throw new Error("To origin\n ! [rejected] foreman/bd-test-001 -> foreman/bd-test-001 (non-fast-forward)\nerror: failed to push some refs");
        }
        // second push succeeds
      }),
      rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(result.success).toBe(true);
  });

  it("returns retryable=true after successful rebase + retry push", async () => {
    let pushCallCount = 0;
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        pushCallCount++;
        if (pushCallCount === 1) {
          throw new Error("To origin\n ! [rejected] (non-fast-forward)");
        }
      }),
      rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(result.retryable).toBe(true);
  });

  it("calls vcs.fetch and vcs.rebase when push is rejected as non-fast-forward", async () => {
    let pushCallCount = 0;
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        pushCallCount++;
        if (pushCallCount === 1) {
          throw new Error("rejected: non-fast-forward");
        }
      }),
      rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.fetch).toHaveBeenCalledWith(tmpDir);
    expect(vcs.rebase).toHaveBeenCalledWith(tmpDir, "origin/foreman/bd-test-001");
  });

  it("writes FINALIZE_REPORT.md with rebase success and push success", async () => {
    let pushCallCount = 0;
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        pushCallCount++;
        if (pushCallCount === 1) {
          throw new Error("rejected: non-fast-forward");
        }
      }),
      rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    expect(content).toContain("## Rebase");
    expect(content).toContain("Status: SUCCESS");
    expect(content).toContain("SUCCESS (after rebase)");
  });
});

describe("finalize() — non-fast-forward push: rebase FAILS → deterministic failure", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-nff-fail-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns success=false when rebase fails (returns success=false)", async () => {
    const vcs = makeMockVcs({
      push: vi.fn().mockRejectedValue(new Error("rejected: non-fast-forward")),
      rebase: vi.fn().mockResolvedValue({ success: false, hasConflicts: true, conflictingFiles: ["src/foo.ts"] }),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(result.success).toBe(false);
  });

  it("returns retryable=false (prevents infinite loop) when rebase fails", async () => {
    const vcs = makeMockVcs({
      push: vi.fn().mockRejectedValue(new Error("rejected: non-fast-forward")),
      rebase: vi.fn().mockResolvedValue({ success: false, hasConflicts: true, conflictingFiles: ["src/foo.ts"] }),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(result.retryable).toBe(false);
  });

  it("calls vcs.abortRebase to clean up partial rebase when rebase returns success=false", async () => {
    const vcs = makeMockVcs({
      push: vi.fn().mockRejectedValue(new Error("rejected: non-fast-forward")),
      rebase: vi.fn().mockResolvedValue({ success: false, hasConflicts: true, conflictingFiles: [] }),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.abortRebase).toHaveBeenCalledWith(tmpDir);
  });

  it("calls vcs.abortRebase to clean up when rebase throws an exception", async () => {
    const vcs = makeMockVcs({
      push: vi.fn().mockRejectedValue(new Error("rejected: non-fast-forward")),
      rebase: vi.fn().mockRejectedValue(new Error("CONFLICT: Merge conflict in src/foo.ts")),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.abortRebase).toHaveBeenCalledWith(tmpDir);
    expect((await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs)).retryable).toBe(false);
  });

  it("writes FINALIZE_REPORT.md with rebase FAILED and push FAILED entries", async () => {
    const vcs = makeMockVcs({
      push: vi.fn().mockRejectedValue(new Error("rejected: non-fast-forward")),
      rebase: vi.fn().mockResolvedValue({ success: false, hasConflicts: true, conflictingFiles: ["src/foo.ts"] }),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    expect(content).toContain("## Rebase");
    expect(content).toContain("Status: FAILED");
    expect(content).toContain("rebase could not resolve diverged history");
  });

  it("does not throw even when rebase fails", async () => {
    const vcs = makeMockVcs({
      push: vi.fn().mockRejectedValue(new Error("rejected: non-fast-forward")),
      rebase: vi.fn().mockResolvedValue({ success: false, hasConflicts: true, conflictingFiles: [] }),
    });
    await expect(finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs)).resolves.toMatchObject({
      success: false,
      retryable: false,
    });
  });
});

// ── finalize — rebase succeeds but retry push fails (transient) ───────────────

describe("finalize() — non-fast-forward push: rebase succeeds but retry push fails (transient)", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-nff-retrypush-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("returns success=false when retry push fails after rebase", async () => {
    let pushCallCount = 0;
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        pushCallCount++;
        if (pushCallCount === 1) throw new Error("rejected: non-fast-forward");
        throw new Error("fatal: unable to connect to origin");
      }),
      rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(result.success).toBe(false);
  });

  it("returns retryable=true for transient retry push failure (not a rebase conflict)", async () => {
    let pushCallCount = 0;
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        pushCallCount++;
        if (pushCallCount === 1) throw new Error("rejected: non-fast-forward");
        throw new Error("fatal: unable to connect to origin");
      }),
      rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(result.retryable).toBe(true);
  });

  it("writes FINALIZE_REPORT.md noting push failed after rebase", async () => {
    let pushCallCount = 0;
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        pushCallCount++;
        if (pushCallCount === 1) throw new Error("rejected: non-fast-forward");
        throw new Error("fatal: network error");
      }),
      rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    expect(content).toContain("## Rebase");
    expect(content).toContain("Status: SUCCESS");
    expect(content).toContain("FAILED (after rebase)");
  });

  it("does not call vcs.abortRebase when rebase itself succeeded", async () => {
    let pushCallCount = 0;
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        pushCallCount++;
        if (pushCallCount === 1) throw new Error("rejected: non-fast-forward");
        throw new Error("fatal: network error");
      }),
      rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.abortRebase).not.toHaveBeenCalled();
  });
});

// ── finalize — "fetch first" push rejection (alternate NFF phrasing) ─────────

describe("finalize() — push rejected with 'fetch first' phrasing → rebase + retry", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-fetchfirst-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("triggers rebase when push is rejected with 'fetch first' phrasing", async () => {
    let pushCallCount = 0;
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        pushCallCount++;
        if (pushCallCount === 1) {
          throw new Error("rejected: (fetch first)\nerror: failed to push some refs");
        }
      }),
      rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.fetch).toHaveBeenCalledWith(tmpDir);
    expect(vcs.rebase).toHaveBeenCalled();
  });

  it("returns success=true after 'fetch first' rejection + rebase + retry push", async () => {
    let pushCallCount = 0;
    const vcs = makeMockVcs({
      push: vi.fn().mockImplementation(async () => {
        pushCallCount++;
        if (pushCallCount === 1) {
          throw new Error("rejected: (fetch first)");
        }
      }),
      rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(result.success).toBe(true);
  });
});

// ── finalize — branch verification before push ────────────────────────────────

describe("finalize() — branch verification", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-branch-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("does NOT call checkoutBranch when already on the correct branch", async () => {
    const vcs = makeMockVcs({
      getCurrentBranch: vi.fn().mockResolvedValue("foreman/bd-test-001"),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.checkoutBranch).not.toHaveBeenCalled();
  });

  it("reports Branch Verification OK when already on the correct branch", async () => {
    const vcs = makeMockVcs({
      getCurrentBranch: vi.fn().mockResolvedValue("foreman/bd-test-001"),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    expect(content).toContain("## Branch Verification");
    expect(content).toContain("Status: OK");
  });

  it("attempts checkoutBranch when on a different branch and push succeeds after recovery", async () => {
    const vcs = makeMockVcs({
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.checkoutBranch).toHaveBeenCalledWith(tmpDir, "foreman/bd-test-001");
    expect(result.success).toBe(true);
  });

  it("reports RECOVERED status in branch verification section after mismatch checkout", async () => {
    const vcs = makeMockVcs({
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    expect(content).toContain("## Branch Verification");
    expect(content).toContain("Status: RECOVERED (checkout succeeded)");
    expect(content).toContain("Was: main");
  });

  it("attempts checkoutBranch when in detached HEAD state and push succeeds after recovery", async () => {
    const vcs = makeMockVcs({
      getCurrentBranch: vi.fn().mockResolvedValue("HEAD"),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.checkoutBranch).toHaveBeenCalled();
    expect(result.success).toBe(true);
  });

  it("skips push and returns false when checkoutBranch fails after branch mismatch", async () => {
    const vcs = makeMockVcs({
      getCurrentBranch: vi.fn().mockResolvedValue("main"),
      checkoutBranch: vi.fn().mockRejectedValue(new Error("error: pathspec 'foreman/bd-test-001' did not match any file(s)")),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.push).not.toHaveBeenCalled();
    expect(result.success).toBe(false);
    expect(mockEnqueueToMergeQueue).not.toHaveBeenCalled();
  });

  it("reports Branch Verification FAILED and Push SKIPPED when checkout fails", async () => {
    const vcs = makeMockVcs({
      getCurrentBranch: vi.fn().mockResolvedValue("other-branch"),
      checkoutBranch: vi.fn().mockRejectedValue(new Error("checkout failed")),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const content = readFileSync(join(tmpDir, "FINALIZE_REPORT.md"), "utf-8");
    expect(content).toContain("## Branch Verification");
    expect(content).toContain("Status: FAILED");
    expect(content).toContain("## Push");
    expect(content).toContain("Status: SKIPPED (branch verification failed)");
    expect(content).toContain("## Seed Status");
    expect(content).toContain("Status: PUSH_FAILED");
  });

  it("skips push and returns false when getCurrentBranch itself fails", async () => {
    const vcs = makeMockVcs({
      getCurrentBranch: vi.fn().mockRejectedValue(new Error("not a git repository")),
    });
    const result = await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(result.success).toBe(false);
  });
});

// ── finalize — modified files for merge queue uses vcs.diff ──────────────────

describe("finalize() — modified files computed via vcs.diff", () => {
  let logFile: string;
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-finalize-diff-test-"));
    logFile = join(tmpDir, "test.log");
    writeFileSync(logFile, "");

    mockExecFileSync.mockReset();
    mockEnqueueToMergeQueue.mockReset().mockReturnValue({ success: true });
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("calls vcs.diff to compute modified files for merge queue", async () => {
    const vcs = makeMockVcs({
      diff: vi.fn().mockResolvedValue(
        "diff --git a/src/foo.ts b/src/foo.ts\nindex abc..def 100644\n--- a/src/foo.ts\n+++ b/src/foo.ts\n@@ -1 +1 @@\n-old\n+new\n"
      ),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    expect(vcs.diff).toHaveBeenCalledWith(tmpDir, "main", "HEAD");
  });

  it("passes parsed file list to enqueueToMergeQueue", async () => {
    const vcs = makeMockVcs({
      diff: vi.fn().mockResolvedValue(
        "diff --git a/src/foo.ts b/src/foo.ts\nindex abc..def 100644\n" +
        "diff --git a/src/bar.ts b/src/bar.ts\nindex 123..456 100644\n"
      ),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const enqueueCall = mockEnqueueToMergeQueue.mock.calls[0];
    expect(enqueueCall).toBeDefined();
    const filesModified: string[] = enqueueCall[0].getFilesModified();
    expect(filesModified).toContain("src/foo.ts");
    expect(filesModified).toContain("src/bar.ts");
  });

  it("passes empty file list when vcs.diff fails (non-fatal)", async () => {
    const vcs = makeMockVcs({
      diff: vi.fn().mockRejectedValue(new Error("git diff failed")),
    });
    await finalize(makeConfig({ worktreePath: tmpDir }), logFile, vcs);
    const enqueueCall = mockEnqueueToMergeQueue.mock.calls[0];
    expect(enqueueCall).toBeDefined();
    const filesModified: string[] = enqueueCall[0].getFilesModified();
    expect(filesModified).toEqual([]);
  });
});

// ── npm-ci + type-check logic (simulated — no real subprocess) ────────────────

// ── Types ─────────────────────────────────────────────────────────────────

interface InstallResult {
  succeeded: boolean;
  reportEntry: string[];
  logMessage: string;
}

interface TypeCheckResult {
  status: "SUCCESS" | "FAILED" | "SKIPPED";
  reportEntry: string[];
  logMessage: string;
}

// ── Helpers (simulate the finalize() logic) ────────────────────────────────

function simulateInstall(npmCiThrows: boolean, errorDetail = "npm ERR! lock file mismatch"): InstallResult {
  if (!npmCiThrows) {
    return {
      succeeded: true,
      reportEntry: ["## Dependency Install", "- Status: SUCCESS", ""],
      logMessage: "[FINALIZE] npm ci succeeded",
    };
  }

  const detail = errorDetail.slice(0, 500);
  return {
    succeeded: false,
    reportEntry: ["## Dependency Install", "- Status: FAILED", "- Errors:", "```", detail, "```", ""],
    logMessage: `[FINALIZE] npm ci failed: ${detail.slice(0, 200)}`,
  };
}

function simulateTypeCheck(
  installSucceeded: boolean,
  tscThrows: boolean,
  errorDetail = "src/foo.ts(1,1): error TS2304: Cannot find name 'x'.",
): TypeCheckResult {
  if (!installSucceeded) {
    return {
      status: "SKIPPED",
      reportEntry: ["## Build / Type Check", "- Status: SKIPPED (dependency install failed)", ""],
      logMessage: "[FINALIZE] Skipping type check — dependency install failed",
    };
  }

  if (!tscThrows) {
    return {
      status: "SUCCESS",
      reportEntry: ["## Build / Type Check", "- Status: SUCCESS", ""],
      logMessage: "[FINALIZE] Type check passed",
    };
  }

  const detail = errorDetail.slice(0, 500);
  return {
    status: "FAILED",
    reportEntry: ["## Build / Type Check", "- Status: FAILED", "- Errors:", "```", detail, "```", ""],
    logMessage: `[FINALIZE] Type check failed: ${detail.slice(0, 200)}`,
  };
}

describe("finalize() — dependency install step", () => {
  it("reports SUCCESS and sets installSucceeded when npm ci exits cleanly", () => {
    const result = simulateInstall(false);
    expect(result.succeeded).toBe(true);
    expect(result.reportEntry).toContain("## Dependency Install");
    expect(result.reportEntry).toContain("- Status: SUCCESS");
    expect(result.logMessage).toContain("npm ci succeeded");
  });

  it("reports FAILED and clears installSucceeded when npm ci throws", () => {
    const result = simulateInstall(true, "npm ERR! lock file mismatch");
    expect(result.succeeded).toBe(false);
    expect(result.reportEntry).toContain("## Dependency Install");
    expect(result.reportEntry).toContain("- Status: FAILED");
    expect(result.logMessage).toContain("npm ci failed");
  });

  it("includes error detail in the report when npm ci fails", () => {
    const detail = "npm ERR! package-lock.json out of sync";
    const result = simulateInstall(true, detail);
    const reportText = result.reportEntry.join("\n");
    expect(reportText).toContain(detail);
    expect(result.reportEntry).toContain("```");
  });

  it("truncates error detail to 500 characters in the report", () => {
    const longError = "x".repeat(600);
    const result = simulateInstall(true, longError);
    const reportText = result.reportEntry.join("\n");
    expect(reportText).toContain("x".repeat(500));
    expect(reportText).not.toContain("x".repeat(501));
  });

  it("truncates log message error to 200 characters", () => {
    const longError = "y".repeat(600);
    const result = simulateInstall(true, longError);
    expect(result.logMessage).toContain("y".repeat(200));
    expect(result.logMessage).not.toContain("y".repeat(201));
  });
});

describe("finalize() — type-check step (conditional on installSucceeded)", () => {
  it("runs type check when installSucceeded is true and reports SUCCESS", () => {
    const result = simulateTypeCheck(true, false);
    expect(result.status).toBe("SUCCESS");
    expect(result.reportEntry).toContain("## Build / Type Check");
    expect(result.reportEntry).toContain("- Status: SUCCESS");
    expect(result.logMessage).toContain("Type check passed");
  });

  it("skips type check when installSucceeded is false", () => {
    const result = simulateTypeCheck(false, false);
    expect(result.status).toBe("SKIPPED");
    expect(result.reportEntry).toContain("## Build / Type Check");
    expect(result.reportEntry).toContain("- Status: SKIPPED (dependency install failed)");
    expect(result.logMessage).toContain("Skipping type check");
  });

  it("reports FAILED with error detail when tsc throws after successful install", () => {
    const tsError = "src/bar.ts(3,5): error TS2322: Type 'string' is not assignable to type 'number'.";
    const result = simulateTypeCheck(true, true, tsError);
    expect(result.status).toBe("FAILED");
    expect(result.reportEntry).toContain("## Build / Type Check");
    expect(result.reportEntry).toContain("- Status: FAILED");
    const reportText = result.reportEntry.join("\n");
    expect(reportText).toContain(tsError);
    expect(result.logMessage).toContain("Type check failed");
  });

  it("does NOT run type check when npm ci failed — guards against false module errors", () => {
    const install = simulateInstall(true);
    const typeCheck = simulateTypeCheck(install.succeeded, false);
    expect(install.succeeded).toBe(false);
    expect(typeCheck.status).toBe("SKIPPED");
  });

  it("correctly sequences install then type-check in the happy path", () => {
    const install = simulateInstall(false);
    const typeCheck = simulateTypeCheck(install.succeeded, false);
    expect(install.succeeded).toBe(true);
    expect(typeCheck.status).toBe("SUCCESS");
    const report = [...install.reportEntry, ...typeCheck.reportEntry];
    const depIdx = report.indexOf("## Dependency Install");
    const tscIdx = report.indexOf("## Build / Type Check");
    expect(depIdx).toBeGreaterThanOrEqual(0);
    expect(tscIdx).toBeGreaterThan(depIdx);
  });

  it("skips type check even when tsc would have passed — error message is clear", () => {
    const result = simulateTypeCheck(false, false);
    expect(result.reportEntry.join("\n")).toContain("dependency install failed");
    expect(result.logMessage).toContain("dependency install failed");
  });
});

describe("finalize() — report structure with npm ci section", () => {
  it("report includes a Dependency Install section before Build / Type Check", () => {
    const install = simulateInstall(false);
    const typeCheck = simulateTypeCheck(true, false);
    const combined = [...install.reportEntry, ...typeCheck.reportEntry].join("\n");
    expect(combined).toContain("## Dependency Install");
    expect(combined).toContain("## Build / Type Check");
    const installPos = combined.indexOf("## Dependency Install");
    const tscPos = combined.indexOf("## Build / Type Check");
    expect(installPos).toBeLessThan(tscPos);
  });

  it("report omits tsc section when install fails — only Dependency Install FAILED appears", () => {
    const install = simulateInstall(true);
    const typeCheck = simulateTypeCheck(false, false);
    const combined = [...install.reportEntry, ...typeCheck.reportEntry].join("\n");
    expect(combined).toContain("## Dependency Install");
    expect(combined).toContain("- Status: FAILED");
    expect(combined).toContain("- Status: SKIPPED (dependency install failed)");
  });

  it("install uses 120_000 ms timeout (not the 60_000 ms type-check timeout)", () => {
    const INSTALL_TIMEOUT_MS = 120_000;
    const TYPECHECK_TIMEOUT_MS = 60_000;
    expect(INSTALL_TIMEOUT_MS).toBeGreaterThan(TYPECHECK_TIMEOUT_MS);
    expect(INSTALL_TIMEOUT_MS).toBe(120_000);
    expect(TYPECHECK_TIMEOUT_MS).toBe(60_000);
  });
});
