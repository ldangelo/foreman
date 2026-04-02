/**
 * TRD-012-TEST: Verify Refinery VcsBackend Migration
 *
 * Acceptance criteria:
 *   AC-T-012-1: Given a mock VcsBackend, when Refinery.mergeCompleted() runs
 *               a clean squash merge, then `vcs.mergeWithoutCommit()` is invoked
 *               and the seed is closed.
 *   AC-T-012-2: Given a squash merge returning conflicts, when refinery processes,
 *               then the conflict resolution cascade is triggered.
 *   AC-T-012-3: refinery.ts no longer imports or calls mergeWorktree().
 *
 * @module src/orchestrator/__tests__/refinery-vcs.test.ts
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { Run } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

// ── Module mocks ─────────────────────────────────────────────────────────────
// NOTE: This suite intentionally keeps a minimal lib/git.js mock because it
// documents migration-boundary expectations while the refinery merge flow still
// has legacy-oriented assertions around shim-era behavior.

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

vi.mock("../../lib/git.js", () => ({
  mergeWorktree: vi.fn(),
  removeWorktree: vi.fn(),
  detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  gitBranchExists: vi.fn().mockResolvedValue(false),
}));

vi.mock("../task-backend-ops.js", () => ({
  enqueueCloseSeed: vi.fn(),
  enqueueResetSeedToOpen: vi.fn(),
  enqueueAddNotesToBead: vi.fn(),
  enqueueSetBeadStatus: vi.fn(),
}));

vi.mock("../../lib/archive-reports.js", () => ({
  archiveWorktreeReports: vi.fn().mockResolvedValue(undefined),
  REPORT_FILES: [],
}));

import { execFile } from "node:child_process";
import { enqueueCloseSeed, enqueueResetSeedToOpen } from "../task-backend-ops.js";
import { Refinery } from "../refinery.js";

// ── VcsBackend Mock Factory ───────────────────────────────────────────────────

/**
 * Creates a fully mocked VcsBackend for testing.
 * Default implementations succeed with sensible defaults.
 * Tests can override individual methods using the overrides parameter.
 */
function makeMockVcs(overrides: Partial<Record<keyof VcsBackend, ReturnType<typeof vi.fn>>> = {}): VcsBackend {
  return {
    name: "git",
    // Repository introspection
    getRepoRoot: vi.fn().mockResolvedValue("/repo"),
    getMainRepoRoot: vi.fn().mockResolvedValue("/repo"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    // Branch operations
    checkoutBranch: vi.fn().mockResolvedValue(undefined),
    branchExists: vi.fn().mockResolvedValue(false),
    branchExistsOnRemote: vi.fn().mockResolvedValue(false),
    deleteBranch: vi.fn().mockResolvedValue({ deleted: true }),
    // Workspace operations
    createWorkspace: vi.fn().mockResolvedValue({ workspacePath: "/workspace", branchName: "foreman/seed-abc" }),
    removeWorkspace: vi.fn().mockResolvedValue(undefined),
    listWorkspaces: vi.fn().mockResolvedValue([]),
    // Staging and commit
    stageAll: vi.fn().mockResolvedValue(undefined),
    stageFile: vi.fn().mockResolvedValue(undefined),
    checkoutFile: vi.fn().mockResolvedValue(undefined),
    commit: vi.fn().mockResolvedValue(undefined),
    commitNoEdit: vi.fn().mockResolvedValue(undefined),
    push: vi.fn().mockResolvedValue(undefined),
    pull: vi.fn().mockResolvedValue(undefined),
    // Rebase and merge
    rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    abortRebase: vi.fn().mockResolvedValue(undefined),
    abortMerge: vi.fn().mockResolvedValue(undefined),
    merge: vi.fn().mockResolvedValue({ success: true }),
    mergeWithoutCommit: vi.fn().mockResolvedValue({ success: true }),
    resetHard: vi.fn().mockResolvedValue(undefined),
    // Diff, status, conflict detection
    getHeadId: vi.fn().mockResolvedValue("abc1234"),
    resolveRef: vi.fn().mockResolvedValue("abc1234"),
    fetch: vi.fn().mockResolvedValue(undefined),
    diff: vi.fn().mockResolvedValue(""),
    getChangedFiles: vi.fn().mockResolvedValue([]),
    getRefCommitTimestamp: vi.fn().mockResolvedValue(null),
    getModifiedFiles: vi.fn().mockResolvedValue([]),
    getConflictingFiles: vi.fn().mockResolvedValue([]),
    status: vi.fn().mockResolvedValue(""),
    cleanWorkingTree: vi.fn().mockResolvedValue(undefined),
    // Finalize support
    getFinalizeCommands: vi.fn().mockReturnValue({
      stageCommand: "git add -A",
      commitCommand: "git commit -m",
      pushCommand: "git push -u origin",
      integrateTargetCommand: "git pull --rebase origin",
      branchVerifyCommand: "git rev-parse --abbrev-ref HEAD",
      cleanCommand: "git clean -fd",
      restoreTrackedStateCommand: "git restore --source=HEAD --staged --worktree -- .beads/issues.jsonl",
    }),
    ...overrides,
  } as VcsBackend;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: null,
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    base_branch: null,
    ...overrides,
  };
}

function makeMocks(vcsOverrides: Partial<Record<keyof VcsBackend, ReturnType<typeof vi.fn>>> = {}) {
  const mockDb = {
    prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })),
  };
  const store = {
    getRunsByStatus: vi.fn(() => [] as Run[]),
    getRunsByStatuses: vi.fn(() => [] as Run[]),
    getRun: vi.fn(() => null as Run | null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRunsByBaseBranch: vi.fn(() => [] as Run[]),
    sendMessage: vi.fn(),
    getDb: vi.fn(() => mockDb),
  };
  const seeds = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
    update: vi.fn(async () => undefined),
  };
  const vcs = makeMockVcs(vcsOverrides);

  // Set up execFile to succeed by default for helper shell calls like gh.
  (execFile as any).mockImplementation(
    (_cmd: string, args: string[], _opts: any, callback: Function) => {
      if (Array.isArray(args) && args[0] === "log") {
        callback(null, { stdout: "abc1234 some commit\n", stderr: "" });
      } else {
        callback(null, { stdout: "", stderr: "" });
      }
    },
  );

  const refinery = new Refinery(store as any, seeds as any, "/tmp/project", vcs);
  return { store, seeds, refinery, vcs };
}

// ── AC-T-012-1: Clean Squash Merge ──────────────────────────────────────────

describe("AC-T-012-1: Clean squash merge invokes git merge --squash and closes the seed", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("invokes git merge --squash with the feature branch on clean merge", async () => {
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun({ seed_id: "seed-001" });
    store.getRunsByStatus.mockReturnValue([run]);

    await refinery.mergeCompleted({ runTests: false });

    // checkoutBranch should be called to switch to target before squash merge
    expect(vcs.checkoutBranch).toHaveBeenCalledWith("/tmp/project", "main");
    expect(vcs.mergeWithoutCommit).toHaveBeenCalledWith(
      "/tmp/project",
      "foreman/seed-001",
      "main",
    );
  });

  it("closes the seed via enqueueCloseSeed after a successful merge", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ seed_id: "seed-001" });
    store.getRunsByStatus.mockReturnValue([run]);

    await refinery.mergeCompleted({ runTests: false });

    // AC-T-012-1: seed must be closed after merge
    expect(enqueueCloseSeed).toHaveBeenCalledWith(
      expect.anything(),
      "seed-001",
      "refinery",
    );
  });

  it("marks run as merged in store after clean merge", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ seed_id: "seed-002" });
    store.getRunsByStatus.mockReturnValue([run]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].seedId).toBe("seed-002");
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "merged" }),
    );
  });

  it("does NOT call enqueueCloseSeed when squash merge has conflicts", async () => {
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun({ seed_id: "seed-003" });
    store.getRunsByStatus.mockReturnValue([run]);

    // Squash merge fails with conflict; gh not available -> falls back to conflict tracking
    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (cmd === "gh") {
          callback(new Error("gh not available"), null);
        } else if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );
    (vcs as any).mergeWithoutCommit = vi
      .fn()
      .mockRejectedValue(new Error("CONFLICT (content): Merge conflict in src/main.ts"));
    (vcs as any).getConflictingFiles = vi.fn().mockResolvedValue(["src/main.ts"]);

    await refinery.mergeCompleted({ runTests: false });

    // AC-T-012-1: seed should NOT be closed on failure
    expect(enqueueCloseSeed).not.toHaveBeenCalled();
  });

  it("calls vcs.detectDefaultBranch() to resolve target branch when not specified", async () => {
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);

    await refinery.mergeCompleted({ runTests: false }); // no targetBranch

    // vcs.detectDefaultBranch should be called to determine the target
    expect(vcs.detectDefaultBranch).toHaveBeenCalledWith("/tmp/project");
  });
});

// ── AC-T-012-2: Conflict Cascade Triggered ────────────────────────────────────

describe("AC-T-012-2: Conflict cascade triggered when squash merge has conflicts", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("triggers conflict cascade when squash merge returns code conflicts", async () => {
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun({ seed_id: "seed-conflict" });
    store.getRunsByStatus.mockReturnValue([run]);

    // gh pr create fails -> falls back to conflict tracking
    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (cmd === "gh") {
          callback(new Error("gh not available"), null);
        } else if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );
    (vcs as any).mergeWithoutCommit = vi
      .fn()
      .mockRejectedValue(new Error("CONFLICT (content): Merge conflict"));
    (vcs as any).getConflictingFiles = vi
      .fn()
      .mockResolvedValue(["src/main.ts", "src/lib/utils.ts"]);

    const report = await refinery.mergeCompleted({ runTests: false });

    // AC-T-012-2: conflict cascade must be triggered
    expect(report.conflicts).toHaveLength(1);
    expect(report.conflicts[0].seedId).toBe("seed-conflict");
    expect(report.conflicts[0].conflictFiles).toContain("src/main.ts");
  });

  it("calls enqueueResetSeedToOpen when conflicts are detected", async () => {
    const conflictFiles = ["src/main.ts", "src/index.ts"];
    const { store, refinery, vcs } = makeMocks();
    // Override after makeMocks to ensure our mock is used
    (vcs as any).getConflictingFiles = vi.fn().mockResolvedValue(conflictFiles);
    (vcs as any).mergeWithoutCommit = vi.fn().mockRejectedValue(new Error("CONFLICT: merge conflict"));
    const run = makeRun({ seed_id: "seed-reset" });
    store.getRunsByStatus.mockReturnValue([run]);

    await refinery.mergeCompleted({ runTests: false });

    // AC-T-012-2: conflict cascade triggers seed reset so it can be retried
    expect(enqueueResetSeedToOpen).toHaveBeenCalledWith(
      expect.anything(),
      "seed-reset",
      "refinery",
    );
  });

  it("attempts gh pr create as part of conflict cascade", async () => {
    const conflictFiles = ["src/conflict.ts"];
    const { store, refinery, vcs } = makeMocks();
    // Override after makeMocks to ensure our mock is used
    (vcs as any).getConflictingFiles = vi.fn().mockResolvedValue(conflictFiles);
    (vcs as any).mergeWithoutCommit = vi.fn().mockRejectedValue(new Error("CONFLICT: merge conflict"));
    const run = makeRun({ seed_id: "seed-pr" });
    store.getRunsByStatus.mockReturnValue([run]);

    const prUrl = "https://github.com/org/repo/pull/42";
    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (cmd === "gh" && Array.isArray(args) && args.includes("create")) {
          callback(null, { stdout: prUrl, stderr: "" });
        } else if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const report = await refinery.mergeCompleted({ runTests: false });

    // AC-T-012-2: conflict cascade should trigger PR creation
    expect(report.prsCreated).toHaveLength(1);
    expect(report.prsCreated[0].prUrl).toBe(prUrl);
  });

  it("does not close seed on conflict -- only closes on successful merge", async () => {
    const conflictFiles = ["src/main.ts"];
    const { store, refinery, vcs } = makeMocks();
    // Override after makeMocks to ensure our mock is used
    (vcs as any).getConflictingFiles = vi.fn().mockResolvedValue(conflictFiles);
    (vcs as any).mergeWithoutCommit = vi.fn().mockRejectedValue(new Error("CONFLICT: merge conflict"));
    const run = makeRun({ seed_id: "seed-no-close" });
    store.getRunsByStatus.mockReturnValue([run]);

    await refinery.mergeCompleted({ runTests: false });

    // AC-T-012-2: seed should NOT be closed when there are conflicts
    expect(enqueueCloseSeed).not.toHaveBeenCalled();
  });

  it("conflict file list comes from vcs.getConflictingFiles after squash merge", async () => {
    // Verifies that conflict file list comes from vcs.getConflictingFiles
    const conflictFiles = ["src/alpha.ts", "src/beta.ts", "lib/gamma.ts"];
    const getConflictingFilesMock = vi.fn().mockResolvedValue(conflictFiles);
    const { store, refinery, vcs } = makeMocks();
    // Override after makeMocks to ensure our mock is used
    (vcs as any).getConflictingFiles = getConflictingFilesMock;
    (vcs as any).mergeWithoutCommit = vi.fn().mockRejectedValue(new Error("CONFLICT: merge conflict"));
    const run = makeRun({ seed_id: "seed-files" });
    store.getRunsByStatus.mockReturnValue([run]);

    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (cmd === "gh") {
          callback(new Error("gh not available"), null);
        } else if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const report = await refinery.mergeCompleted({ runTests: false });

    // The conflict files should come from vcs.getConflictingFiles
    expect(getConflictingFilesMock).toHaveBeenCalled();
    expect(report.conflicts[0].conflictFiles).toEqual(conflictFiles);
  });
});

// ── AC-T-012-3: mergeWorktree replaced ─────────────────────────────────────

describe("AC-T-012-3: refinery.ts no longer imports or calls mergeWorktree", () => {
  it("refinery.ts does not import mergeWorktree from git.js", () => {
    // Read the refinery.ts source file
    const refineryPath = join(
      import.meta.dirname ?? __dirname,
      "..",
      "..",
      "..",
      "src",
      "orchestrator",
      "refinery.ts",
    );

    let source: string;
    try {
      source = readFileSync(refineryPath, "utf8");
    } catch {
      // Try relative path from test file
      source = readFileSync(
        join(import.meta.url.replace("file://", ""), "..", "..", "refinery.ts"),
        "utf8",
      );
    }

    // AC-T-012-3: mergeWorktree must NOT be imported from git.ts -- it has been
    // replaced by squash merge via gitSpecial in the mergeCompleted() method.
    // Note: gitSpecial() and gitReadOnly() are intentionally kept as private
    // helpers for git operations not covered by VcsBackend (stash, reset --hard,
    // rebase --onto, etc.) -- see no-direct-git.test.ts allowlist for rationale.
    expect(source).not.toMatch(/import.*mergeWorktree.*from/);

    // Also verify that the merge call in mergeCompleted uses squash merge
    expect(source).not.toMatch(/await mergeWorktree\(/);
  });

  it("refinery.ts constructor accepts a VcsBackend parameter", () => {
    // AC-T-012-1 prerequisite: verify VcsBackend is injectable
    const { refinery } = makeMocks();
    expect(refinery).toBeInstanceOf(Refinery);

    // The constructor with all 4 args should work
    const mockDb = { prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })) };
    const store = { getRunsByStatus: vi.fn(() => []), getRunsByStatuses: vi.fn(() => []), getRun: vi.fn(), updateRun: vi.fn(), logEvent: vi.fn(), getRunsByBaseBranch: vi.fn(() => []), sendMessage: vi.fn(), getDb: vi.fn(() => mockDb) };
    const seeds = { getGraph: vi.fn(), show: vi.fn(), update: vi.fn() };
    const vcs = makeMockVcs();
    const r = new Refinery(store as any, seeds as any, "/tmp", vcs);
    expect(r).toBeInstanceOf(Refinery);
  });

  it("mergeCompleted uses vcs.mergeWithoutCommit (not gitSpecial)", async () => {
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);

    await refinery.mergeCompleted({ runTests: false });

    // AC-T-012: Confirm vcs.mergeWithoutCommit was called (replaces git merge --squash via gitSpecial)
    expect(vcs.mergeWithoutCommit).toHaveBeenCalled();
    // Should also have called vcs.commit with the squash message
    expect(vcs.commit).toHaveBeenCalled();
  });
});

// ── AC-T-012-4: removeWorktree replaced by vcs.removeWorkspace() ─────────────

describe("AC-T-012-4: Refinery uses vcs.removeWorkspace() instead of removeWorktree shim", () => {
  it("refinery.ts does not import removeWorktree from git.js (TRD-012)", () => {
    const refineryPath = join(
      import.meta.dirname ?? __dirname,
      "..",
      "..",
      "..",
      "src",
      "orchestrator",
      "refinery.ts",
    );
    const source = readFileSync(refineryPath, "utf8");

    // TRD-012: removeWorktree shim must not be imported -- replaced by vcs.removeWorkspace()
    expect(source).not.toMatch(/import.*removeWorktree.*from/);
    expect(source).not.toMatch(/await removeWorktree\(/);
  });

  it("refinery.ts calls vcs.removeWorkspace() when removing worktree on successful merge", async () => {
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun({ seed_id: "seed-remove-test", worktree_path: "/tmp/worktrees/seed-remove-test" });
    store.getRunsByStatus.mockReturnValue([run]);

    await refinery.mergeCompleted({ runTests: false });

    // AC-T-012-4: vcs.removeWorkspace() should be called after successful merge
    expect(vcs.removeWorkspace).toHaveBeenCalledWith(
      "/tmp/project",
      "/tmp/worktrees/seed-remove-test",
    );
  });
});
