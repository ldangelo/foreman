/**
 * Refinery must never leave the project root on a different branch than the
 * one the developer had checked out before the merge ran.
 *
 * The fallback (non-integration-worktree) merge path checks out the target
 * branch in the project root. These tests verify the originally checked-out
 * branch is captured before any checkout and restored afterward:
 *   - restored after a successful merge
 *   - restored even when the merge fails
 *   - restore skipped when the original branch no longer exists
 *   - restore failures never throw
 *
 * @module src/orchestrator/__tests__/refinery-branch-restore.test.ts
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

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
  enqueueCloseTask: vi.fn(),
  enqueueResetTaskToOpen: vi.fn(),
  enqueueAddNotesToBead: vi.fn(),
  enqueueSetBeadStatus: vi.fn(),
}));

vi.mock("../../lib/archive-reports.js", () => ({
  archiveWorktreeReports: vi.fn().mockResolvedValue(undefined),
  REPORT_FILES: [],
}));

import { execFile } from "node:child_process";
import { Refinery } from "../refinery.js";

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
    createWorkspace: vi.fn().mockResolvedValue({ workspacePath: "/workspace", branchName: "foreman/task-abc" }),
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
    stageFiles: vi.fn().mockResolvedValue(undefined),
    merge: vi.fn().mockResolvedValue({ success: true }),
    mergeWithStrategy: vi.fn().mockResolvedValue({ success: true }),
    rollbackFailedMerge: vi.fn().mockResolvedValue(undefined),
    mergeWithoutCommit: vi.fn().mockResolvedValue({ success: true }),
    resetHard: vi.fn().mockResolvedValue(undefined),
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

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    task_id: "task-abc",
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
  } as Run;
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
  const tasks = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
    update: vi.fn(async () => undefined),
  };
  const vcs = makeMockVcs(vcsOverrides);

  (execFile as any).mockImplementation(
    (_cmd: string, args: string[], _opts: any, callback: Function) => {
      if (Array.isArray(args) && args[0] === "log") {
        callback(null, { stdout: "abc1234 some commit\n", stderr: "" });
      } else {
        callback(null, { stdout: "", stderr: "" });
      }
    },
  );

  // "/tmp/project" has no .git directory, so useIntegrationWorktree is false
  // and the merge runs directly against the project root (the fallback path).
  const refinery = new Refinery(store as any, tasks as any, "/tmp/project", vcs);
  return { store, tasks, refinery, vcs };
}

describe("Refinery restores the original project-root branch (fallback merge path)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("restores the originally checked-out feature branch after a successful merge", async () => {
    const { store, refinery, vcs } = makeMocks({
      getCurrentBranch: vi.fn()
        .mockResolvedValueOnce("fix/my-feature") // captured before the merge
        .mockResolvedValue("main"),              // after merge: left on target
      branchExists: vi.fn().mockResolvedValue(true),
    });
    const run = makeRun({ task_id: "task-001" });
    store.getRunsByStatus.mockReturnValue([run]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(1);
    // Merge path checked out the target branch...
    expect(vcs.checkoutBranch).toHaveBeenCalledWith("/tmp/project", "main");
    // ...and the original branch was restored afterward (last checkout call)
    const calls = (vcs.checkoutBranch as ReturnType<typeof vi.fn>).mock.calls;
    expect(calls[calls.length - 1]).toEqual(["/tmp/project", "fix/my-feature"]);
  });

  it("restores the original branch even when the merge fails", async () => {
    const { store, refinery, vcs } = makeMocks({
      getCurrentBranch: vi.fn()
        .mockResolvedValueOnce("fix/my-feature")
        .mockResolvedValue("main"),
      branchExists: vi.fn().mockResolvedValue(true),
      mergeWithoutCommit: vi.fn().mockRejectedValue(new Error("boom — unexpected merge error")),
    });
    const run = makeRun({ task_id: "task-002" });
    store.getRunsByStatus.mockReturnValue([run]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(0);
    const calls = (vcs.checkoutBranch as ReturnType<typeof vi.fn>).mock.calls;
    expect(calls[calls.length - 1]).toEqual(["/tmp/project", "fix/my-feature"]);
  });

  it("skips restore when the original branch no longer exists", async () => {
    const { store, refinery, vcs } = makeMocks({
      getCurrentBranch: vi.fn()
        .mockResolvedValueOnce("fix/deleted-branch")
        .mockResolvedValue("main"),
      branchExists: vi.fn().mockResolvedValue(false),
    });
    const run = makeRun({ task_id: "task-003" });
    store.getRunsByStatus.mockReturnValue([run]);

    await refinery.mergeCompleted({ runTests: false });

    expect(vcs.checkoutBranch).not.toHaveBeenCalledWith("/tmp/project", "fix/deleted-branch");
  });

  it("never throws when the restore checkout fails", async () => {
    const { store, refinery } = makeMocks({
      getCurrentBranch: vi.fn()
        .mockResolvedValueOnce("fix/my-feature")
        .mockResolvedValue("main"),
      branchExists: vi.fn().mockResolvedValue(true),
      checkoutBranch: vi.fn().mockImplementation(async (_path: string, branch: string) => {
        if (branch === "fix/my-feature") throw new Error("checkout failed: dirty tree");
      }),
    });
    const run = makeRun({ task_id: "task-004" });
    store.getRunsByStatus.mockReturnValue([run]);

    await expect(refinery.mergeCompleted({ runTests: false })).resolves.toBeDefined();
  });

  it("does not perform an extra checkout when the project root was already on the target branch", async () => {
    const { store, refinery, vcs } = makeMocks(); // getCurrentBranch always "main"
    const run = makeRun({ task_id: "task-005" });
    store.getRunsByStatus.mockReturnValue([run]);

    await refinery.mergeCompleted({ runTests: false });

    const calls = (vcs.checkoutBranch as ReturnType<typeof vi.fn>).mock.calls;
    expect(calls.every(([, branch]) => branch === "main")).toBe(true);
  });
});
