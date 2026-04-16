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
    getChangedFiles: vi.fn().mockResolvedValue(["packages/development/commands/create-trd-foreman.yaml"]),
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

  it("rebases stacked jj branches with jj rebase -b instead of raw git rebase --onto", async () => {
    const mockDb = {
      prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })),
    };
    const mergedRun = makeRun({ id: "run-jj-merged", seed_id: "seed-jj" });
    const stackedRun = makeRun({
      id: "run-jj-stacked",
      seed_id: "seed-jj-2",
      status: "running",
      base_branch: "foreman/seed-jj",
      worktree_path: "/tmp/jj-workspace-2",
    });
    const store = {
      getRunsByStatus: vi.fn(() => [mergedRun]),
      getRunsByStatuses: vi.fn(() => []),
      getRun: vi.fn(() => null),
      updateRun: vi.fn(),
      logEvent: vi.fn(),
      getRunsByBaseBranch: vi.fn(() => [stackedRun]),
      sendMessage: vi.fn(),
      getDb: vi.fn(() => mockDb),
    };
    const seeds = {
      getGraph: vi.fn(async () => ({ edges: [] })),
      show: vi.fn(async () => null),
      update: vi.fn(async () => undefined),
    };
    const vcs = makeMockVcs();
    (vcs.getChangedFiles as any).mockResolvedValue(["packages/development/commands/create-trd-foreman.yaml"]);
    const refinery = new Refinery(store as any, seeds as any, "/tmp/project", vcs);

    await refinery.mergeCompleted({ runTests: false });

    const jjRebaseCalls = (execFile as any).mock.calls.filter(
      (call: any[]) => call[0] === "jj" && Array.isArray(call[1]) && call[1][0] === "rebase" && call[1][1] === "-b",
    );
    expect(jjRebaseCalls).toHaveLength(1);
    expect(jjRebaseCalls[0][1]).toEqual(["rebase", "-b", "foreman/seed-jj-2", "-d", "dev"]);

    const gitRebaseCalls = (execFile as any).mock.calls.filter(
      (call: any[]) => call[0] === "git" && Array.isArray(call[1]) && call[1][0] === "rebase",
    );
    expect(gitRebaseCalls).toHaveLength(0);
  });

  it("passes the injected jj backend through to the conflict resolver", () => {
    const mockDb = {
      prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })),
    };
    const store = {
      getRunsByStatus: vi.fn(() => []),
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
    const refinery = new Refinery(store as any, seeds as any, "/tmp/project", vcs) as any;

    expect(refinery.conflictResolver.vcs).toBe(vcs);
  });

  it("uses jj log instead of raw git log when building PR commit summaries", async () => {
    const mockDb = {
      prepare: vi.fn(() => ({ get: vi.fn(() => undefined), run: vi.fn() })),
    };
    const run = makeRun({ id: "run-pr-jj", seed_id: "seed-pr-jj", worktree_path: null });
    const store = {
      getRunsByStatus: vi.fn((status: string) => (status === "completed" ? [run] : [])),
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

    await refinery.createPRs({ baseBranch: "dev" });

    const jjLogCalls = (execFile as any).mock.calls.filter(
      (call: any[]) => call[0] === "jj" && Array.isArray(call[1]) && call[1][0] === "log",
    );
    expect(jjLogCalls).toHaveLength(1);
    expect(jjLogCalls[0][1]).toEqual([
      "log",
      "--no-graph",
      "-r",
      "dev::foreman/seed-pr-jj",
      "-T",
      "commit_id.short() ++ \" \" ++ description ++ \"\\n\"",
    ]);

    const gitLogCalls = (execFile as any).mock.calls.filter(
      (call: any[]) => call[0] === "git" && Array.isArray(call[1]) && call[1][0] === "log",
    );
    expect(gitLogCalls).toHaveLength(0);
  });
});
