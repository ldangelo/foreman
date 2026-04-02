import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
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
import { Refinery } from "../refinery.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-jj-1",
    project_id: "proj-1",
    seed_id: "seed-jj",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/jj-workspace",
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    base_branch: null,
    ...overrides,
  };
}

function makeMockVcs(): VcsBackend {
  return {
    name: "jujutsu",
    getRepoRoot: vi.fn().mockResolvedValue("/repo"),
    getMainRepoRoot: vi.fn().mockResolvedValue("/repo"),
    detectDefaultBranch: vi.fn().mockResolvedValue("dev"),
    getCurrentBranch: vi.fn().mockResolvedValue("dev"),
    checkoutBranch: vi.fn().mockResolvedValue(undefined),
    branchExists: vi.fn().mockResolvedValue(true),
    branchExistsOnRemote: vi.fn().mockResolvedValue(true),
    deleteBranch: vi.fn().mockResolvedValue({ deleted: true, wasFullyMerged: true }),
    createWorkspace: vi.fn().mockResolvedValue({ workspacePath: "/tmp/jj-workspace", branchName: "foreman/seed-jj" }),
    removeWorkspace: vi.fn().mockResolvedValue(undefined),
    listWorkspaces: vi.fn().mockResolvedValue([]),
    stageAll: vi.fn().mockResolvedValue(undefined),
    stageFile: vi.fn().mockResolvedValue(undefined),
    checkoutFile: vi.fn().mockResolvedValue(undefined),
    showFile: vi.fn().mockResolvedValue(""),
    commit: vi.fn().mockResolvedValue(undefined),
    commitNoEdit: vi.fn().mockResolvedValue(undefined),
    push: vi.fn().mockResolvedValue(undefined),
    pull: vi.fn().mockResolvedValue(undefined),
    rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    abortRebase: vi.fn().mockResolvedValue(undefined),
    merge: vi.fn().mockResolvedValue({ success: true }),
    mergeWithoutCommit: vi.fn().mockResolvedValue({ success: true }),
    abortMerge: vi.fn().mockResolvedValue(undefined),
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
    status: vi.fn().mockResolvedValue("M FINALIZE_VALIDATION.md"),
    cleanWorkingTree: vi.fn().mockResolvedValue(undefined),
    getFinalizeCommands: vi.fn().mockReturnValue({
      stageCommand: "",
      commitCommand: "jj describe -m",
      pushCommand: "jj git push --bookmark",
      integrateTargetCommand: "jj rebase -d dev",
      branchVerifyCommand: "jj log -r @",
      cleanCommand: "jj restore",
      restoreTrackedStateCommand: "",
    }),
  } as unknown as VcsBackend;
}

describe("Refinery jj rebase path", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc123 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );
  });

  it("rebases jj runs in the run worktree instead of raw git rebase in the repo root", async () => {
    const mockDb = {
      prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })),
    };
    const store = {
      getRunsByStatus: vi.fn(() => [makeRun()]),
      getRunsByStatuses: vi.fn(() => []),
      getRun: vi.fn(() => null),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getRunsByBaseBranch: vi.fn(() => []),
      sendMessage: vi.fn(),
      getDb: vi.fn(() => mockDb),
    };
    const seeds = {
      getGraph: vi.fn(async () => ({ edges: [] })),
      show: vi.fn(async () => null),
      update: vi.fn(async () => undefined),
    };
    const vcs = makeMockVcs();
    const refinery = new Refinery(store as any, seeds as any, "/tmp/project", vcs);

    await refinery.mergeCompleted({ runTests: false });

    expect(vcs.cleanWorkingTree).toHaveBeenCalledWith("/tmp/jj-workspace");
    expect(vcs.rebase).toHaveBeenCalledWith("/tmp/jj-workspace", "dev");

    const gitRebaseCalls = (execFile as any).mock.calls.filter(
      (call: any[]) => call[0] === "git" && Array.isArray(call[1]) && call[1][0] === "rebase",
    );
    expect(gitRebaseCalls).toHaveLength(0);
  });
});
