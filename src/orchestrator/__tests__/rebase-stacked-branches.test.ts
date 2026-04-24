/**
 * Tests for Refinery.rebaseStackedBranches() — rebases stacked branches onto
 * main after their base dependency branch is merged.
 *
 * rebaseStackedBranches() is private, so we test it indirectly by calling
 * mergeCompleted() in scenarios where stacked runs exist.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

vi.mock("../task-backend-ops.js", () => ({
  enqueueResetSeedToOpen: vi.fn(),
  enqueueCloseSeed: vi.fn(),
  enqueueSetBeadStatus: vi.fn(),
  enqueueAddNotesToBead: vi.fn(),
}));

import { execFile } from "node:child_process";
import { Refinery } from "../refinery.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/worktrees/seed-abc",
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    base_branch: null,
    ...overrides,
  };
}

function makeMockVcs(overrides: Partial<Record<keyof VcsBackend, ReturnType<typeof vi.fn>>> = {}): VcsBackend {
  return {
    name: "git",
    getRepoRoot: vi.fn().mockResolvedValue("/repo"),
    getMainRepoRoot: vi.fn().mockResolvedValue("/repo"),
    detectDefaultBranch: vi.fn().mockResolvedValue("main"),
    getCurrentBranch: vi.fn().mockResolvedValue("main"),
    checkoutBranch: vi.fn().mockResolvedValue(undefined),
    branchExists: vi.fn().mockResolvedValue(false),
    branchExistsOnRemote: vi.fn().mockResolvedValue(false),
    deleteBranch: vi.fn().mockResolvedValue({ deleted: true }),
    createWorkspace: vi.fn().mockResolvedValue({ workspacePath: "/workspace", branchName: "foreman/story-1" }),
    removeWorkspace: vi.fn().mockResolvedValue(undefined),
    listWorkspaces: vi.fn().mockResolvedValue([]),
    stageAll: vi.fn().mockResolvedValue(undefined),
    stageFile: vi.fn().mockResolvedValue(undefined),
    checkoutFile: vi.fn().mockResolvedValue(undefined),
    commit: vi.fn().mockResolvedValue(undefined),
    commitNoEdit: vi.fn().mockResolvedValue(undefined),
    push: vi.fn().mockResolvedValue(undefined),
    pull: vi.fn().mockResolvedValue(undefined),
    saveWorktreeState: vi.fn().mockResolvedValue(false),
    restoreWorktreeState: vi.fn().mockResolvedValue(undefined),
    rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    rebaseBranch: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    restackBranch: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    abortRebase: vi.fn().mockResolvedValue(undefined),
    abortMerge: vi.fn().mockResolvedValue(undefined),
    stageFile: vi.fn().mockResolvedValue(undefined),
    stageFiles: vi.fn().mockResolvedValue(undefined),
    merge: vi.fn().mockResolvedValue({ success: true }),
    mergeWithStrategy: vi.fn().mockResolvedValue({ success: true }),
    rollbackFailedMerge: vi.fn().mockResolvedValue(undefined),
    mergeWithoutCommit: vi.fn().mockResolvedValue({ success: true }),
    resetHard: vi.fn().mockResolvedValue(undefined),
    removeFile: vi.fn().mockResolvedValue(undefined),
    rebaseContinue: vi.fn().mockResolvedValue(undefined),
    removeFromIndex: vi.fn().mockResolvedValue(undefined),
    getMergeBase: vi.fn().mockResolvedValue("abc123"),
    getUntrackedFiles: vi.fn().mockResolvedValue([]),
    getHeadId: vi.fn().mockResolvedValue("abc123"),
    resolveRef: vi.fn().mockResolvedValue("abc123"),
    fetch: vi.fn().mockResolvedValue(undefined),
    diff: vi.fn().mockResolvedValue(""),
    getChangedFiles: vi.fn().mockResolvedValue([]),
    getRefCommitTimestamp: vi.fn().mockResolvedValue(null),
    getModifiedFiles: vi.fn().mockResolvedValue([]),
    getConflictingFiles: vi.fn().mockResolvedValue([]),
    status: vi.fn().mockResolvedValue(""),
    cleanWorkingTree: vi.fn().mockResolvedValue(undefined),
    isAncestor: vi.fn().mockResolvedValue(true),
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

function makeMocks(
  stackedRuns: Run[] = [],
  vcsOverrides: Partial<Record<keyof VcsBackend, ReturnType<typeof vi.fn>>> = {},
) {
  const mockDb = {
    prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })),
  };
  const store = {
    getRunsByStatus: vi.fn(() => [] as Run[]),
    getRunsByStatuses: vi.fn(() => [] as Run[]),
    getRun: vi.fn(() => null as Run | null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRunsByBaseBranch: vi.fn(() => stackedRuns),
    getDb: vi.fn(() => mockDb),
    sendMessage: vi.fn(),
  };
  const seeds = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
    update: vi.fn(async () => undefined),
  };
  const vcs = makeMockVcs(vcsOverrides);
  const refinery = new Refinery(store as any, seeds as any, "/tmp/project", vcs);
  return { store, seeds, refinery, vcs };
}

describe("Refinery.rebaseStackedBranches() (via mergeCompleted)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );
  });

  it("calls getRunsByBaseBranch with the merged branch name after a successful merge", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const { store, refinery } = makeMocks([]);
    store.getRunsByStatus.mockReturnValue([mergedRun]);

    await refinery.mergeCompleted({ runTests: false });

    expect(store.getRunsByBaseBranch).toHaveBeenCalledWith("foreman/story-1");
  });

  it("rebases stacked branches onto target via VcsBackend.restackBranch", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const stackedRun = makeRun({ id: "run-2", seed_id: "story-2", status: "running", base_branch: "foreman/story-1" });
    const branchExists = vi.fn().mockResolvedValue(true);
    const restackBranch = vi.fn().mockResolvedValue({ success: true, hasConflicts: false });
    const { store, refinery, vcs } = makeMocks([stackedRun], { branchExists, restackBranch });
    store.getRunsByStatus.mockReturnValue([mergedRun]);

    await refinery.mergeCompleted({ runTests: false });

    expect(vcs.branchExists).toHaveBeenCalledWith("/tmp/project", "foreman/story-2");
    expect(vcs.restackBranch).toHaveBeenCalledWith(
      "/tmp/project",
      "foreman/story-2",
      "foreman/story-1",
      "main",
    );
  });

  it("skips rebasing stacked run when its branch does not exist locally", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const stackedRun = makeRun({ id: "run-2", seed_id: "story-2", status: "running", base_branch: "foreman/story-1" });
    const { store, refinery, vcs } = makeMocks([stackedRun], {
      branchExists: vi.fn().mockResolvedValue(false),
      restackBranch: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    store.getRunsByStatus.mockReturnValue([mergedRun]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(1);
    expect(vcs.restackBranch).not.toHaveBeenCalled();
  });

  it("skips rebasing stacked runs with terminal statuses (merged, failed)", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const stackedRun = makeRun({ id: "run-2", seed_id: "story-2", status: "merged", base_branch: "foreman/story-1" });
    const { store, refinery, vcs } = makeMocks([stackedRun], {
      branchExists: vi.fn().mockResolvedValue(true),
      restackBranch: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    store.getRunsByStatus.mockReturnValue([mergedRun]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(1);
    expect(vcs.restackBranch).not.toHaveBeenCalled();
  });

  it("merge succeeds even if restack of stacked branch fails", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const stackedRun = makeRun({ id: "run-2", seed_id: "story-2", status: "running", base_branch: "foreman/story-1" });
    const { store, refinery, vcs } = makeMocks([stackedRun], {
      branchExists: vi.fn().mockResolvedValue(true),
      restackBranch: vi.fn().mockResolvedValue({ success: false, hasConflicts: true, conflictingFiles: ["src/conflict.ts"] }),
      abortRebase: vi.fn().mockResolvedValue(undefined),
    });
    store.getRunsByStatus.mockReturnValue([mergedRun]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(1);
    expect(report.testFailures).toHaveLength(0);
    expect(vcs.restackBranch).toHaveBeenCalled();
    expect(vcs.abortRebase).toHaveBeenCalledWith("/tmp/project");
  });

  it("updates base_branch to null in store when rebase succeeds", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const stackedRun = makeRun({ id: "run-2", seed_id: "story-2", status: "running", base_branch: "foreman/story-1" });
    const { store, refinery } = makeMocks([stackedRun], {
      branchExists: vi.fn().mockResolvedValue(true),
      restackBranch: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    });
    store.getRunsByStatus.mockReturnValue([mergedRun]);

    await refinery.mergeCompleted({ runTests: false });

    expect(store.updateRun).toHaveBeenCalledWith(
      "run-2",
      expect.objectContaining({ base_branch: null }),
    );
  });
});
