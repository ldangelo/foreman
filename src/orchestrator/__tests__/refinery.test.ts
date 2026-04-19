import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

// ── Module mocks ─────────────────────────────────────────────────────────────
// NOTE: This suite intentionally retains lib/git.js mocks/imports as
// compatibility coverage for the transitional refinery/shim surface.
// New runtime code should prefer VcsBackend/VcsBackendFactory instead.

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

vi.mock("../../lib/git.js", () => ({
  mergeWorktree: vi.fn(),
  removeWorktree: vi.fn(),
  detectDefaultBranch: vi.fn().mockResolvedValue("main"),
  gitBranchExists: vi.fn().mockResolvedValue(false),
}));

// Mock task-backend-ops so closeSeed() / resetSeedToOpen() don't try to execute the real `br` binary.
vi.mock("../task-backend-ops.js", () => ({
  enqueueCloseSeed: vi.fn(),
  enqueueResetSeedToOpen: vi.fn(),
  enqueueAddNotesToBead: vi.fn(),
  enqueueSetBeadStatus: vi.fn(),
}));

// Mock auto-merge so syncBeadStatusAfterMerge can be spied on in tests.
vi.mock("../auto-merge.js", () => ({
  syncBeadStatusAfterMerge: vi.fn().mockResolvedValue(undefined),
}));

// Import mocked modules AFTER vi.mock declarations
import { execFile } from "node:child_process";
import { removeWorktree } from "../../lib/git.js";
import { enqueueCloseSeed, enqueueResetSeedToOpen, enqueueAddNotesToBead } from "../task-backend-ops.js";
import { syncBeadStatusAfterMerge } from "../auto-merge.js";
import { Refinery } from "../refinery.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

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

/** Create a mock VcsBackend with sane defaults (merge succeeds, detect = "main"). */
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
    createWorkspace: vi.fn().mockResolvedValue({ workspacePath: "/workspace", branchName: "foreman/seed-abc" }),
    removeWorkspace: vi.fn().mockResolvedValue(undefined),
    listWorkspaces: vi.fn().mockResolvedValue([]),
    stageAll: vi.fn().mockResolvedValue(undefined),
    stageFile: vi.fn().mockResolvedValue(undefined),
    checkoutFile: vi.fn().mockResolvedValue(undefined),
    commit: vi.fn().mockResolvedValue(undefined),
    commitNoEdit: vi.fn().mockResolvedValue(undefined),
    push: vi.fn().mockResolvedValue(undefined),
    pull: vi.fn().mockResolvedValue(undefined),
    rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    abortRebase: vi.fn().mockResolvedValue(undefined),
    abortMerge: vi.fn().mockResolvedValue(undefined),
    /** merge() defaults to success — tests can override via overrides.merge */
    merge: vi.fn().mockResolvedValue({ success: true }),
    mergeWithoutCommit: vi.fn().mockResolvedValue({ success: true }),
    resetHard: vi.fn().mockResolvedValue(undefined),
    getHeadId: vi.fn().mockResolvedValue("abc1234"),
    fetch: vi.fn().mockResolvedValue(undefined),
    diff: vi.fn().mockResolvedValue(""),
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

function makeMocks(vcsOverrides: Partial<Record<keyof VcsBackend, ReturnType<typeof vi.fn>>> = {}) {
  (execFile as any).mockImplementation(
    (_cmd: string, args: string[], _opts: any, callback: Function) => {
      if (Array.isArray(args) && args[0] === "log") {
        callback(null, { stdout: "abc1234 some commit\n", stderr: "" });
      } else {
        callback(null, { stdout: "", stderr: "" });
      }
    },
  );

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
  const refinery = new Refinery(store as any, seeds as any, "/tmp/project", vcs);
  return { store, seeds, refinery, vcs };
}

// Helper to make execFile resolve with a stdout value
function mockExecFileSuccess(stdout = "") {
  (execFile as any).mockImplementation(
    (_cmd: string, _args: string[], _opts: any, callback: Function) => {
      callback(null, { stdout, stderr: "" });
    },
  );
}

// Helper to make execFile reject
function mockExecFileFailure(message = "git error") {
  (execFile as any).mockImplementation(
    (_cmd: string, _args: string[], _opts: any, callback: Function) => {
      const err = new Error(message) as any;
      err.stdout = "";
      err.stderr = message;
      callback(err);
    },
  );
}

// ── resolveConflict() tests ───────────────────────────────────────────────────

describe("Refinery.resolveConflict()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("throws when run is not found", async () => {
    const { store, refinery } = makeMocks();
    store.getRun.mockReturnValue(null);

    await expect(refinery.resolveConflict("missing-id", "theirs")).rejects.toThrow(
      "Run missing-id not found",
    );
  });

  it("abort strategy marks run as failed and returns false", async () => {
    const { store, seeds, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    const result = await refinery.resolveConflict("run-1", "abort");

    expect(result).toBe(false);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "failed" }),
    );
    expect(store.logEvent).toHaveBeenCalledWith(
      run.project_id,
      "fail",
      expect.objectContaining({ reason: expect.stringContaining("abort") }),
      run.id,
    );
    expect(enqueueAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(), run.seed_id, expect.stringContaining("aborted"), "refinery",
    );
  });

  it("theirs strategy calls git checkout and merge, marks run as merged, returns true", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    // execFile is used by the promisified git() helper inside resolveConflict
    // vitest doesn't auto-promisify, so we need to handle the promisified call
    // The promisify(execFile) version calls with (cmd, args, opts) returning a promise
    // We mock execFile but node's promisify wraps it - let's use a different approach
    // by mocking the callback-style execFile that promisify wraps
    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    const result = await refinery.resolveConflict("run-1", "theirs");

    expect(result).toBe(true);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "merged" }),
    );
    expect(store.logEvent).toHaveBeenCalledWith(
      run.project_id,
      "merge",
      expect.objectContaining({ strategy: "theirs" }),
      run.id,
    );
  });

  it("theirs strategy marks run as failed if git merge fails", async () => {
    const { store, seeds, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        const err = new Error("CONFLICT (content): Merge conflict in README.md") as any;
        err.stdout = "";
        err.stderr = "CONFLICT (content): Merge conflict in README.md";
        callback(err);
      },
    );

    // Provide targetBranch explicitly to avoid calling vcsBackend.detectDefaultBranch()
    // (which would also fail since ALL execFile calls throw in this mock).
    const result = await refinery.resolveConflict("run-1", "theirs", { targetBranch: "main" });

    expect(result).toBe(false);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "failed" }),
    );

    // Ensure git merge --abort is called to leave the repo in a clean state
    const calls: string[][] = (execFile as any).mock.calls.map((c: any[]) => c[1]);
    const abortCall = calls.find((args) => Array.isArray(args) && args.includes("--abort"));
    expect(abortCall).toBeDefined();
    expect(enqueueAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(), run.seed_id, expect.stringContaining("Merge failed"), "refinery",
    );

    // Merge conflicts remain blocked until an explicit human retry/reset.
    expect(enqueueResetSeedToOpen).not.toHaveBeenCalled();
  });

  it("theirs strategy uses provided targetBranch in git checkout", async () => {
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    await refinery.resolveConflict("run-1", "theirs", { targetBranch: "develop", runTests: false });

    // vcsBackend.checkoutBranch() is now used instead of raw execFile("git", ["checkout", ...])
    expect(vcs.checkoutBranch).toHaveBeenCalledWith(expect.any(String), "develop");
  });

  it("theirs strategy defaults to main when no targetBranch provided", async () => {
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    await refinery.resolveConflict("run-1", "theirs", { runTests: false });

    // vcsBackend.checkoutBranch() is used; default branch = "main" (from vcs.detectDefaultBranch mock)
    expect(vcs.checkoutBranch).toHaveBeenCalledWith(expect.any(String), "main");
  });

  it("theirs strategy marks run as test-failed and reverts when tests fail after merge", async () => {
    const { store, seeds, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    // git checkout + git merge succeed; npm test fails; git reset succeeds
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (_cmd === "npm" || (Array.isArray(args) && args.includes("test"))) {
          const err = new Error("Tests failed") as any;
          err.stdout = "FAIL src/foo.test.ts";
          err.stderr = "Tests failed";
          callback(err);
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const result = await refinery.resolveConflict("run-1", "theirs", {
      runTests: true,
      testCommand: "npm test",
    });

    expect(result).toBe(false);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "test-failed" }),
    );

    // Ensure git reset --hard HEAD~1 was called to revert the merge
    const calls: string[][] = (execFile as any).mock.calls.map((c: any[]) => c[1]);
    const resetCall = calls.find(
      (args) => Array.isArray(args) && args.includes("reset") && args.includes("--hard"),
    );
    expect(resetCall).toBeDefined();
    expect(enqueueAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(), run.seed_id, expect.stringContaining("tests failed"), "refinery",
    );

    // Test failures remain blocked until an explicit human retry/reset.
    expect(enqueueResetSeedToOpen).not.toHaveBeenCalled();
  });

  it("theirs strategy marks run as merged when tests pass after merge", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    const result = await refinery.resolveConflict("run-1", "theirs", {
      runTests: true,
      testCommand: "npm test",
    });

    expect(result).toBe(true);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "merged" }),
    );
  });

  it("theirs strategy skips tests when runTests is false", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    const result = await refinery.resolveConflict("run-1", "theirs", { runTests: false });

    expect(result).toBe(true);
    // Verify no npm/test command was invoked
    const calls: string[] = (execFile as any).mock.calls.map((c: any[]) => c[0]);
    const testCallMade = calls.some((cmd) => cmd === "npm");
    expect(testCallMade).toBe(false);
  });

  it("theirs strategy removes worktree on success", async () => {
    // TRD-012: removeWorktree shim replaced by vcs.removeWorkspace()
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict", worktree_path: "/tmp/worktrees/seed-abc" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );

    await refinery.resolveConflict("run-1", "theirs");

    expect(vcs.removeWorkspace).toHaveBeenCalledWith("/tmp/project", "/tmp/worktrees/seed-abc");
  });

  it("theirs strategy succeeds even if worktree removal fails", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict", worktree_path: "/tmp/worktrees/seed-abc" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockRejectedValue(new Error("worktree not found"));

    const result = await refinery.resolveConflict("run-1", "theirs");

    // Should still succeed; worktree removal failure is non-fatal
    expect(result).toBe(true);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "merged" }),
    );
  });
});

// ── mergeCompleted() tests ────────────────────────────────────────────────────

describe("Refinery.mergeCompleted()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    // Default execFile mock for mergeCompleted tests:
    // - git log returns a non-empty commit list so the "no unique commits" guard passes.
    // - All other git/gh calls succeed with empty stdout.
    // Individual tests can override this for specific scenarios.
    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (cmd === "git" && Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 some commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );
  });

  it("returns empty report when no completed runs exist", async () => {
    const { store, refinery } = makeMocks();
    store.getRunsByStatus.mockReturnValue([]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(0);
    expect(report.conflicts).toHaveLength(0);
    expect(report.testFailures).toHaveLength(0);
  });

  it("marks run as merged on clean merge with tests disabled", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);
    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].seedId).toBe(run.seed_id);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "merged" }),
    );
  });

  it("uses branch: label from bead as target branch instead of default", async () => {
    const { store, seeds, refinery, vcs } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);
    (removeWorktree as any).mockResolvedValue(undefined);

    // Mock seeds.show to return a bead with a branch: label
    seeds.show.mockResolvedValue({
      title: "Test bead",
      description: null,
      status: "completed",
      labels: ["workflow:smoke", "branch:installer"],
    } as unknown as null);

    await refinery.mergeCompleted({ runTests: false });

    // checkoutBranch should be called with "installer" as targetBranch (squash merge checks out target first)
    expect(vcs.checkoutBranch).toHaveBeenCalledWith(
      expect.any(String),
      "installer",
    );
    expect(vcs.mergeWithoutCommit).toHaveBeenCalledWith(
      "/tmp/project",
      "foreman/seed-abc",
      "installer",
    );
  });

  it("falls back to default branch when bead has no branch: label", async () => {
    const { store, seeds, refinery, vcs } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);
    (removeWorktree as any).mockResolvedValue(undefined);

    // Mock seeds.show to return a bead with no branch: label
    seeds.show.mockResolvedValue({
      title: "Test bead",
      description: null,
      status: "completed",
      labels: ["workflow:smoke"],
    } as unknown as null);

    await refinery.mergeCompleted({ runTests: false });

    // checkoutBranch should be called with "main" (from detectDefaultBranch mock)
    expect(vcs.checkoutBranch).toHaveBeenCalledWith(
      expect.any(String),
      "main",
    );
  });

  it("marks run as conflict when merge has conflicts", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);

    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (cmd === "gh") {
          const err = new Error("gh not available") as any;
          err.stdout = "";
          err.stderr = "gh not available";
          callback(err);
        } else if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 some commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );
    (refinery as any).vcsBackend.mergeWithoutCommit = vi
      .fn()
      .mockRejectedValue(new Error("CONFLICT (content): Merge conflict in src/main.ts"));
    (refinery as any).vcsBackend.getConflictingFiles = vi
      .fn()
      .mockResolvedValue(["src/main.ts", "src/index.ts"]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.conflicts).toHaveLength(1);
    expect(report.conflicts[0].conflictFiles).toContain("src/main.ts");
    // resetSeedToOpen must be called so the seed reappears in the ready queue
    expect(enqueueResetSeedToOpen).not.toHaveBeenCalled();
  });

  it("adds failure note when code-conflict PR creation fails", async () => {
    const { store, seeds, refinery } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);

    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (cmd === "gh") {
          const err = new Error("gh not available") as any;
          err.stdout = "";
          err.stderr = "gh not available";
          callback(err);
        } else if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 some commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );
    (refinery as any).vcsBackend.mergeWithoutCommit = vi
      .fn()
      .mockRejectedValue(new Error("CONFLICT (content): Merge conflict in src/index.ts"));
    (refinery as any).vcsBackend.getConflictingFiles = vi
      .fn()
      .mockResolvedValue(["src/index.ts"]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.conflicts).toHaveLength(1);
    // Must add a note explaining what happened before the reset
    expect(enqueueAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(), run.seed_id, expect.stringContaining("manual retry required"), "refinery",
    );
  });

  it("adds failure note when rebase-conflict PR creation fails", async () => {
    const { store, seeds, refinery } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);

    // Sequence of git calls:
    //   1. git status --porcelain         → "" (autoCommitStateFiles: no dirty files)
    //   2. git rebase main foreman/seed-abc → CONFLICT (rebase fails)
    //   3. git diff --name-only --diff-filter=U → "src/index.ts" (real code conflict)
    //   4. git rebase --abort             → success
    //   5. git checkout main              → success (return to target branch)
    //   6. git push (for PR creation)     → fails (gh not available)
    // → createPrForConflict returns null → addFailureNote must be called
    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (cmd === "gh") {
          const err = new Error("gh not available") as any;
          err.stdout = "";
          err.stderr = "gh not available";
          callback(err);
        } else if (Array.isArray(args) && args[0] === "rebase" && args.length > 1 && args[1] !== "--abort") {
          // git rebase <target> <branch> — fail with conflict
          const err = new Error("CONFLICT during rebase") as any;
          err.stdout = "";
          err.stderr = "CONFLICT during rebase";
          callback(err);
        } else if (Array.isArray(args) && args[0] === "diff" && args.includes("--diff-filter=U")) {
          // git diff --name-only --diff-filter=U → real code conflict file
          callback(null, { stdout: "src/index.ts\n", stderr: "" });
        } else if (cmd === "git" && Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 some commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.conflicts).toHaveLength(1);
    // Must add a note explaining what happened before the reset
    expect(enqueueAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(), run.seed_id, expect.stringContaining("manual retry required"), "refinery",
    );
  });

  it("marks run as test-failed when tests fail after merge", async () => {
    const { store, seeds, refinery } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);

    // First call for tests (npm test), fails; second call for git reset, succeeds
    let callCount = 0;
    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        callCount++;
        if (args.includes("test") || cmd.includes("npm")) {
          // Test command failure
          const err = new Error("Tests failed") as any;
          err.stdout = "FAIL src/foo.test.ts";
          err.stderr = "Tests failed";
          callback(err);
        } else if (cmd === "git" && Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 some commit\n", stderr: "" });
        } else {
          // git reset success
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const report = await refinery.mergeCompleted({
      runTests: true,
      testCommand: "npm test",
    });

    expect(report.testFailures).toHaveLength(1);
    expect(report.testFailures[0].seedId).toBe(run.seed_id);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "test-failed" }),
    );
    expect(enqueueAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(), run.seed_id, expect.stringContaining("tests failed"), "refinery",
    );
  });

  it("merges in dependency order", async () => {
    const { store, seeds, refinery } = makeMocks();
    const runA = makeRun({ id: "run-a", seed_id: "seed-a" });
    const runB = makeRun({ id: "run-b", seed_id: "seed-b" });
    store.getRunsByStatus.mockReturnValue([runB, runA]); // B first (wrong order)
    // seed-b depends on seed-a — so seed-a should merge first
    (seeds.getGraph as any).mockResolvedValue({
      nodes: [],
      edges: [{ from: "seed-b", to: "seed-a", type: "blocks" }],
    });
    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(2);
    // seed-a (dependency) should merge first
    expect(report.merged[0].seedId).toBe("seed-a");
    expect(report.merged[1].seedId).toBe("seed-b");
  });

  it("applies seedId filter when provided", async () => {
    const { store, refinery } = makeMocks();
    const runA = makeRun({ id: "run-a", seed_id: "seed-target" });
    const runB = makeRun({ id: "run-b", seed_id: "seed-other" });
    // When seedId is specified, getCompletedRuns uses getRunsByStatuses (not getRunsByStatus)
    store.getRunsByStatuses.mockReturnValue([runA, runB]);
    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false, seedId: "seed-target" });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].seedId).toBe("seed-target");
  });

  it("catches unexpected errors and puts run in unexpectedErrors (not testFailures)", async () => {
    const { store, seeds, refinery } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);

    // Simulate a non-conflict backend failure on the squash merge
    (refinery as any).vcsBackend.mergeWithoutCommit = vi
      .fn()
      .mockRejectedValue(new Error("Unexpected git failure"));

    const report = await refinery.mergeCompleted({ runTests: false });

    // Fix 3: git/shell errors go to unexpectedErrors, NOT testFailures
    expect(report.testFailures).toHaveLength(0);
    expect(report.unexpectedErrors).toHaveLength(1);
    expect(report.unexpectedErrors[0].error).toContain("Unexpected git failure");
    expect(enqueueAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(), run.seed_id, expect.stringContaining("Merge failed"), "refinery",
    );
  });

  it("retries a previously-failed seed: finds run in test-failed state when seedId is specified", async () => {
    // Reproduces: "no completed run found for seed <seedid>" after a failed merge.
    // When --bead is supplied, getCompletedRuns() must also look in terminal failure
    // states so the user can retry without manually resetting the run.
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-retry", seed_id: "seed-retry", status: "test-failed" });

    // Normal getRunsByStatus("completed") returns nothing (the run is test-failed)
    store.getRunsByStatus.mockReturnValue([]);
    // getRunsByStatuses with the retry-eligible statuses returns the failed run
    store.getRunsByStatuses.mockReturnValue([run]);

    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false, seedId: "seed-retry" });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].seedId).toBe("seed-retry");
    // Confirm getRunsByStatuses was called (not just getRunsByStatus)
    expect(store.getRunsByStatuses).toHaveBeenCalled();
  });

  it("retries a previously-failed seed: finds run in conflict state when seedId is specified", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-conflict-retry", seed_id: "seed-conflict", status: "conflict" });

    store.getRunsByStatus.mockReturnValue([]);
    store.getRunsByStatuses.mockReturnValue([run]);

    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false, seedId: "seed-conflict" });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].seedId).toBe("seed-conflict");
  });

  it("prefers completed run over newer stuck run when both exist for same seed", async () => {
    // Reproduces: two runs for dashboard-g7l — stuck (created later) and completed (created earlier).
    // getRunsByStatuses returns both; we must use the completed one.
    const { store, refinery } = makeMocks();
    const completedRun = makeRun({ id: "run-old-completed", seed_id: "seed-dup", status: "completed" });
    const stuckRun = makeRun({ id: "run-new-stuck", seed_id: "seed-dup", status: "failed" });

    store.getRunsByStatus.mockReturnValue([]);
    // SQLite returns stuck first (most recent created_at DESC)
    store.getRunsByStatuses.mockReturnValue([stuckRun, completedRun]);

    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false, seedId: "seed-dup" });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].seedId).toBe("seed-dup");
    // Must have used the completed run, not the stuck one
    expect(report.merged[0].runId).toBe("run-old-completed");
  });

  it("without seedId filter, only looks for completed runs (no retry expansion)", async () => {
    const { store, refinery } = makeMocks();
    store.getRunsByStatus.mockReturnValue([]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(0);
    // getRunsByStatuses should NOT be called when no seedId filter is active
    expect(store.getRunsByStatuses).not.toHaveBeenCalled();
  });

  // ── bead close-after-merge tests (bd-jpt4 fix) ───────────────────────────

  it("calls closeSeed after successful merge in mergeCompleted()", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ seed_id: "seed-closeme" });
    store.getRunsByStatus.mockReturnValue([run]);
    (removeWorktree as any).mockResolvedValue(undefined);

    await refinery.mergeCompleted({ runTests: false });

    expect(enqueueCloseSeed).toHaveBeenCalledWith(expect.anything(), "seed-closeme", "refinery");
  });

  it("does NOT call closeSeed when merge has code conflicts", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ seed_id: "seed-conflict" });
    store.getRunsByStatus.mockReturnValue([run]);
    // Squash merge hits a conflict; gh not available → fallback to conflict tracking
    (execFile as any).mockImplementation(
      (cmd: string, _args: string[], _opts: any, callback: Function) => {
        if (cmd === "gh") {
          callback(new Error("gh not available"), { stdout: "", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );
    (refinery as any).vcsBackend.mergeWithoutCommit = vi
      .fn()
      .mockRejectedValue(new Error("CONFLICT (content): Merge conflict in src/index.ts"));
    (refinery as any).vcsBackend.getConflictingFiles = vi
      .fn()
      .mockResolvedValue(["src/index.ts"]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.conflicts).toHaveLength(1);
    expect(enqueueCloseSeed).not.toHaveBeenCalled();
  });

  it("does NOT call closeSeed when tests fail after merge in mergeCompleted()", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ seed_id: "seed-testfail" });
    store.getRunsByStatus.mockReturnValue([run]);

    // git rev-parse succeeds, test command fails, git reset succeeds
    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args) && args.includes("test")) {
          const err = new Error("Tests failed") as any;
          err.stdout = "FAIL";
          err.stderr = "Tests failed";
          callback(err);
        } else if (cmd === "git" && Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 some commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const report = await refinery.mergeCompleted({ runTests: true, testCommand: "npm test" });

    expect(report.testFailures).toHaveLength(1);
    expect(enqueueCloseSeed).not.toHaveBeenCalled();
  });

  // ── Race condition fix: overrideRun bypasses query ─────────────────────────

  it("uses overrideRun to bypass query entirely when provided", async () => {
    // This tests the fix for the auto-merge race condition where finalize marks
    // a run as completed but the query hasn't seen the update yet.
    // Using overrideRun bypasses the getCompletedRuns() query entirely.
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-override", seed_id: "seed-override", status: "completed" });

    // getRunsByStatuses returns nothing (race condition scenario)
    store.getRunsByStatuses.mockReturnValue([]);
    (removeWorktree as any).mockResolvedValue(undefined);

    // Pass overrideRun directly - this bypasses the query
    const report = await refinery.mergeCompleted({
      runTests: false,
      projectId: "proj-1",
      seedId: "seed-override",
      overrideRun: run,
    });

    // Should successfully find and merge the run via overrideRun
    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].seedId).toBe("seed-override");
    // getRunsByStatuses should NOT be called when overrideRun is provided
    expect(store.getRunsByStatuses).not.toHaveBeenCalled();
  });

  it("does NOT call getRunsByStatuses when overrideRun is provided", async () => {
    // When overrideRun is provided, the normal query should be skipped entirely
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-skip-query", seed_id: "seed-skip-query", status: "completed" });

    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({
      runTests: false,
      seedId: "seed-skip-query",
      overrideRun: run,
    });

    expect(report.merged).toHaveLength(1);
    // getRunsByStatuses should NOT be called when overrideRun is provided
    expect(store.getRunsByStatuses).not.toHaveBeenCalled();
    // getRun should NOT be called when overrideRun is provided
    expect(store.getRun).not.toHaveBeenCalled();
  });

  it("skips query and uses overrideRun even when seedId differs", async () => {
    // When overrideRun is provided, the seedId parameter is still used for
    // other purposes (like target branch resolution), but the run lookup is
    // bypassed entirely.
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-seed-a", seed_id: "seed-a", status: "completed" });

    // getRunsByStatuses returns nothing
    store.getRunsByStatuses.mockReturnValue([]);
    (removeWorktree as any).mockResolvedValue(undefined);

    // seedId differs from run's seed_id, but overrideRun bypasses the check
    const report = await refinery.mergeCompleted({
      runTests: false,
      seedId: "seed-b",
      overrideRun: run,
    });

    // Should still merge because overrideRun bypasses seedId matching
    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].seedId).toBe("seed-a");
  });
});

// ── resolveConflict() bead close tests (bd-jpt4 fix) ─────────────────────────

describe("Refinery.resolveConflict() — bead close after merge", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("calls closeSeed after successful resolveConflict (theirs)", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", seed_id: "seed-resolve", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    const result = await refinery.resolveConflict("run-1", "theirs", { runTests: false });

    expect(result).toBe(true);
    expect(enqueueCloseSeed).toHaveBeenCalledWith(expect.anything(), "seed-resolve", "refinery");
  });

  it("does NOT call closeSeed when resolveConflict uses abort strategy", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", seed_id: "seed-abort", status: "conflict" });
    store.getRun.mockReturnValue(run);

    const result = await refinery.resolveConflict("run-1", "abort");

    expect(result).toBe(false);
    expect(enqueueCloseSeed).not.toHaveBeenCalled();
  });

  it("does NOT call closeSeed when resolveConflict git merge fails", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", seed_id: "seed-mergefail", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args) && args.includes("merge") && !args.includes("--abort")) {
          const err = new Error("Merge conflict") as any;
          err.stdout = "";
          err.stderr = "Merge conflict";
          callback(err);
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const result = await refinery.resolveConflict("run-1", "theirs");

    expect(result).toBe(false);
    expect(enqueueCloseSeed).not.toHaveBeenCalled();
  });

  it("does NOT call closeSeed when tests fail after resolveConflict merge", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", seed_id: "seed-testfail-resolve", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args) && args.includes("test")) {
          const err = new Error("Tests failed") as any;
          err.stdout = "FAIL";
          err.stderr = "Tests failed";
          callback(err);
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    const result = await refinery.resolveConflict("run-1", "theirs", {
      runTests: true,
      testCommand: "npm test",
    });

    expect(result).toBe(false);
    expect(enqueueCloseSeed).not.toHaveBeenCalled();
  });
});

// ── orderByDependencies() tests ───────────────────────────────────────────────

describe("Refinery.orderByDependencies()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("returns single run unchanged", async () => {
    const { refinery } = makeMocks();
    const run = makeRun();
    const result = await refinery.orderByDependencies([run]);
    expect(result).toEqual([run]);
  });

  it("returns original order when graph is unavailable", async () => {
    const { seeds, refinery } = makeMocks();
    seeds.getGraph.mockRejectedValue(new Error("No graph"));
    const runA = makeRun({ id: "run-a", seed_id: "seed-a" });
    const runB = makeRun({ id: "run-b", seed_id: "seed-b" });

    const result = await refinery.orderByDependencies([runA, runB]);
    expect(result).toEqual([runA, runB]);
  });

  it("places dependency before dependent", async () => {
    const { seeds, refinery } = makeMocks();
    (seeds.getGraph as any).mockResolvedValue({
      nodes: [],
      edges: [{ from: "seed-b", to: "seed-a", type: "blocks" }], // seed-b depends on seed-a
    });
    const runA = makeRun({ id: "run-a", seed_id: "seed-a" });
    const runB = makeRun({ id: "run-b", seed_id: "seed-b" });

    const result = await refinery.orderByDependencies([runB, runA]);
    expect(result[0].seed_id).toBe("seed-a");
    expect(result[1].seed_id).toBe("seed-b");
  });
});

// ── closeNativeTaskPostMerge() tests (REQ-018) ───────────────────────────────

describe("Refinery.closeNativeTaskPostMerge() (REQ-018)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  // Helper: create mocks with a DB that returns a task row for the given runId
  function makeMocksWithTask(runId: string, taskId: string) {
    const mockDb = {
      prepare: vi.fn((sql: string) => {
        if (sql.includes("SELECT id FROM tasks WHERE run_id")) {
          return { get: vi.fn(() => ({ id: taskId })), run: vi.fn() };
        }
        return { get: vi.fn(() => undefined), run: vi.fn() };
      }),
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
    const vcs = makeMockVcs();
    const refinery = new Refinery(store as any, seeds as any, "/tmp/project", vcs);
    return { store, seeds, refinery, vcs, mockDb };
  }

  // Helper: create mocks with a DB that returns undefined (no task) for the given runId
  function makeMocksWithoutTask() {
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
    const vcs = makeMockVcs();
    const refinery = new Refinery(store as any, seeds as any, "/tmp/project", vcs);
    return { store, seeds, refinery, vcs, mockDb };
  }

  describe("mergeCompleted()", () => {
    it("calls taskStore.updateStatus with 'merged' when a native task exists for the run", async () => {
      const { store, refinery } = makeMocksWithTask("run-task-1", "task-abc");
      const run = makeRun({ id: "run-task-1", seed_id: "seed-task-1" });
      store.getRunsByStatus.mockReturnValue([run]);
      (removeWorktree as any).mockResolvedValue(undefined);

      const taskStore = (refinery as any).taskStore;
      const updateStatusSpy = vi.spyOn(taskStore, "updateStatus");

      await refinery.mergeCompleted({ runTests: false });

      expect(updateStatusSpy).toHaveBeenCalledTimes(1);
      expect(updateStatusSpy).toHaveBeenCalledWith("task-abc", "merged");
    });

    it("does NOT throw when taskStore.updateStatus fails (non-fatal)", async () => {
      const { store, refinery } = makeMocksWithTask("run-task-2", "task-def");
      const run = makeRun({ id: "run-task-2", seed_id: "seed-task-2" });
      store.getRunsByStatus.mockReturnValue([run]);
      (removeWorktree as any).mockResolvedValue(undefined);

      const taskStore = (refinery as any).taskStore;
      vi.spyOn(taskStore, "updateStatus").mockImplementation(() => {
        throw new Error("updateStatus failed");
      });

      // Should not throw — closeNativeTaskPostMerge is non-fatal
      await expect(refinery.mergeCompleted({ runTests: false })).resolves.not.toThrow();
    });

    it("still calls enqueueCloseSeed when using native task fallback", async () => {
      const { store, refinery } = makeMocksWithoutTask();
      const run = makeRun({ id: "run-beads-only", seed_id: "seed-beads-only" });
      store.getRunsByStatus.mockReturnValue([run]);
      (removeWorktree as any).mockResolvedValue(undefined);

      // Reset spy before the call
      (syncBeadStatusAfterMerge as any).mockClear();

      await refinery.mergeCompleted({ runTests: false });

      // enqueueCloseSeed should still be called for the bead
      expect(enqueueCloseSeed).toHaveBeenCalledWith(expect.anything(), "seed-beads-only", "refinery");

      // syncBeadStatusAfterMerge should be called in the fallback path (no native task)
      expect(syncBeadStatusAfterMerge).toHaveBeenCalledTimes(1);
      expect(syncBeadStatusAfterMerge).toHaveBeenCalledWith(
        expect.anything(),
        expect.anything(),
        "run-beads-only",
        "seed-beads-only",
        expect.anything(),
      );
    });
  });

  describe("resolveConflict()", () => {
    it("calls taskStore.updateStatus with 'merged' when a native task exists for the run", async () => {
      const { store, refinery } = makeMocksWithTask("run-conflict-task", "task-xyz");
      const run = makeRun({ id: "run-conflict-task", seed_id: "seed-conflict-task", status: "conflict" });
      store.getRun.mockReturnValue(run);

      (execFile as any).mockImplementation(
        (_cmd: string, _args: string[], _opts: any, callback: Function) => {
          callback(null, { stdout: "", stderr: "" });
        },
      );
      (removeWorktree as any).mockResolvedValue(undefined);

      const taskStore = (refinery as any).taskStore;
      const updateStatusSpy = vi.spyOn(taskStore, "updateStatus");

      const result = await refinery.resolveConflict("run-conflict-task", "theirs", { runTests: false });

      expect(result).toBe(true);
      expect(updateStatusSpy).toHaveBeenCalledTimes(1);
      expect(updateStatusSpy).toHaveBeenCalledWith("task-xyz", "merged");
    });

    it("does NOT throw when taskStore.updateStatus fails in resolveConflict (non-fatal)", async () => {
      const { store, refinery } = makeMocksWithTask("run-conflict-task-2", "task-fail");
      const run = makeRun({ id: "run-conflict-task-2", seed_id: "seed-conflict-task-2", status: "conflict" });
      store.getRun.mockReturnValue(run);

      (execFile as any).mockImplementation(
        (_cmd: string, _args: string[], _opts: any, callback: Function) => {
          callback(null, { stdout: "", stderr: "" });
        },
      );
      (removeWorktree as any).mockResolvedValue(undefined);

      const taskStore = (refinery as any).taskStore;
      vi.spyOn(taskStore, "updateStatus").mockImplementation(() => {
        throw new Error("updateStatus failed");
      });

      // Should not throw — closeNativeTaskPostMerge is non-fatal
      await expect(refinery.resolveConflict("run-conflict-task-2", "theirs", { runTests: false }))
        .resolves.not.toThrow();
    });
  });
});
