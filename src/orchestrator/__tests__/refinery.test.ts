import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

const {
  mockPostgresGetRun,
  mockPostgresListTasks,
  mockPostgresUpdateTask,
  mockPostgresUpdateTaskStatusForRun,
  mockPostgresUpdateRun,
  mockPostgresLogEvent,
  MockPostgresAdapter,
} = vi.hoisted(() => {
  const mockPostgresGetRun = vi.fn().mockResolvedValue(null);
  const mockPostgresListTasks = vi.fn().mockResolvedValue([]);
  const mockPostgresUpdateTask = vi.fn().mockResolvedValue(undefined);
  const mockPostgresUpdateTaskStatusForRun = vi.fn().mockResolvedValue(undefined);
  const mockPostgresUpdateRun = vi.fn().mockResolvedValue(undefined);
  const mockPostgresLogEvent = vi.fn().mockResolvedValue(undefined);
  const MockPostgresAdapter = vi.fn(function (this: Record<string, unknown>) {
    this.getRun = mockPostgresGetRun;
    this.listTasks = mockPostgresListTasks;
    this.updateTask = mockPostgresUpdateTask;
    this.updateTaskStatusForRun = mockPostgresUpdateTaskStatusForRun;
    this.updateRun = mockPostgresUpdateRun;
    this.logEvent = mockPostgresLogEvent;
  });
  return {
    mockPostgresGetRun,
    mockPostgresListTasks,
    mockPostgresUpdateTask,
    mockPostgresUpdateTaskStatusForRun,
    mockPostgresUpdateRun,
    mockPostgresLogEvent,
    MockPostgresAdapter,
  };
});

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

vi.mock("../../lib/db/postgres-adapter.js", () => ({
  PostgresAdapter: MockPostgresAdapter,
}));

// Mock task-backend-ops so closeTask() / resetTaskToOpen() don't try to execute the real `br` binary.
vi.mock("../task-backend-ops.js", () => ({
  enqueueCloseTask: vi.fn(),
  enqueueResetTaskToOpen: vi.fn(),
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
import { enqueueCloseTask, enqueueResetTaskToOpen, enqueueAddNotesToBead } from "../task-backend-ops.js";
import { syncBeadStatusAfterMerge } from "../auto-merge.js";
import { Refinery } from "../refinery.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    task_id: "task-abc",
    agent_type: "claude-code",
    session_key: null,
    worktree_path: "/tmp/worktrees/task-abc",
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
    /** merge() defaults to success — tests can override via overrides.merge */
    merge: vi.fn().mockResolvedValue({ success: true }),
    mergeWithStrategy: vi.fn().mockResolvedValue({ success: true }),
    rollbackFailedMerge: vi.fn().mockResolvedValue(undefined),
    mergeWithoutCommit: vi.fn().mockResolvedValue({ success: true }),
    resetHard: vi.fn().mockResolvedValue(undefined),
    getHeadId: vi.fn().mockResolvedValue("abc1234"),
    resolveRef: vi.fn().mockResolvedValue("abc1234"),
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
  const tasks = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
    update: vi.fn(async () => undefined),
  };
  const vcs = makeMockVcs(vcsOverrides);
  const refinery = new Refinery(store as any, tasks as any, "/tmp/project", vcs);
  return { store, tasks, refinery, vcs, mockDb };
}

function makeRegisteredRefinery(
  store: ReturnType<typeof makeMocks>["store"],
  tasks: ReturnType<typeof makeMocks>["tasks"],
  vcs: ReturnType<typeof makeMocks>["vcs"],
  run: Run,
  registeredProjectId = "proj-1",
) {
  const runLookup = {
    getRun: vi.fn().mockResolvedValue(run),
    getRunsByStatus: vi.fn().mockResolvedValue([run]),
    getRunsByStatuses: vi.fn().mockResolvedValue([run]),
    getRunsByBaseBranch: vi.fn().mockResolvedValue([]),
  };

  const refinery = new Refinery(store as any, tasks as any, "/tmp/project", vcs, {
    runLookup: runLookup as any,
    registeredProjectId,
  });

  return { refinery, runLookup };
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
    mockPostgresListTasks.mockResolvedValue([]);
    mockPostgresUpdateTask.mockResolvedValue(undefined);
    mockPostgresUpdateRun.mockResolvedValue(undefined);
    mockPostgresLogEvent.mockResolvedValue(undefined);
  });

  it("throws when run is not found", async () => {
    const { store, refinery } = makeMocks();
    store.getRun.mockReturnValue(null);

    await expect(refinery.resolveConflict("missing-id", "theirs")).rejects.toThrow(
      "Run missing-id not found",
    );
  });

  it("abort strategy marks run as failed and returns false", async () => {
    const { store, tasks, refinery } = makeMocks();
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
      expect.anything(), run.task_id, expect.stringContaining("aborted"), "refinery",
    );
  });

  it("theirs strategy calls git checkout and merge, marks run as merged, returns true", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

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
    const { store, tasks, refinery, vcs } = makeMocks({
      mergeWithStrategy: vi.fn().mockResolvedValue({ success: false, conflicts: ["README.md"] }),
      abortMerge: vi.fn().mockResolvedValue(undefined),
    });
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    // Provide targetBranch explicitly to avoid calling vcsBackend.detectDefaultBranch()
    const result = await refinery.resolveConflict("run-1", "theirs", { targetBranch: "main" });

    expect(result).toBe(false);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "failed" }),
    );

    expect(vcs.abortMerge).toHaveBeenCalledWith("/tmp/project");
    expect(enqueueAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(), run.task_id, expect.stringContaining("Merge failed"), "refinery",
    );

    // Merge conflicts remain blocked until an explicit human retry/reset.
    expect(enqueueResetTaskToOpen).not.toHaveBeenCalled();
  });

  it("theirs strategy uses provided targetBranch in git checkout", async () => {
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    await refinery.resolveConflict("run-1", "theirs", { targetBranch: "develop", runTests: false });

    expect(vcs.mergeWithStrategy).toHaveBeenCalledWith(
      "/tmp/project",
      "foreman/task-abc",
      "develop",
      "theirs",
    );
  });

  it("theirs strategy defaults to main when no targetBranch provided", async () => {
    const { store, refinery, vcs } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    await refinery.resolveConflict("run-1", "theirs", { runTests: false });

    expect(vcs.mergeWithStrategy).toHaveBeenCalledWith(
      "/tmp/project",
      "foreman/task-abc",
      "main",
      "theirs",
    );
  });

  it("theirs strategy marks run as test-failed and reverts when tests fail after merge", async () => {
    const { store, tasks, refinery, vcs } = makeMocks({
      mergeWithStrategy: vi.fn().mockResolvedValue({ success: true }),
      rollbackFailedMerge: vi.fn().mockResolvedValue(undefined),
    });
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

    expect(vcs.rollbackFailedMerge).toHaveBeenCalled();
    expect(enqueueAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(), run.task_id, expect.stringContaining("tests failed"), "refinery",
    );

    // Test failures remain blocked until an explicit human retry/reset.
    expect(enqueueResetTaskToOpen).not.toHaveBeenCalled();
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
    const run = makeRun({ id: "run-1", status: "conflict", worktree_path: "/tmp/worktrees/task-abc" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );

    await refinery.resolveConflict("run-1", "theirs");

    expect(vcs.removeWorkspace).toHaveBeenCalledWith("/tmp/project", "/tmp/worktrees/task-abc");
  });

  it("theirs strategy succeeds even if worktree removal fails", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict", worktree_path: "/tmp/worktrees/task-abc" });
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

describe("Refinery.mergeCompleted() mail handling", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockPostgresListTasks.mockResolvedValue([]);
    mockPostgresUpdateTask.mockResolvedValue(undefined);
  });

  it("does not throw when lifecycle mail sendMessage() returns rejected promises", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-mail-1", status: "completed" });
    store.getRun.mockReturnValue(run);
    store.sendMessage.mockRejectedValue(new Error("mail write failed"));

    await expect(refinery.mergeCompleted({ runId: run.id, overrideRun: run, runTests: false })).resolves.toMatchObject({
      merged: [{ runId: run.id, taskId: run.task_id, branchName: "foreman/task-abc" }],
    });
  });
});

// ── mergeCompleted() tests ────────────────────────────────────────────────────

describe("Refinery.mergeCompleted()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockPostgresListTasks.mockResolvedValue([]);
    mockPostgresUpdateTask.mockResolvedValue(undefined);
    mockPostgresUpdateTaskStatusForRun.mockResolvedValue(undefined);
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
    expect(report.merged[0].taskId).toBe(run.task_id);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "merged" }),
    );
  });

  it("uses injected async run lookup for registered mergeCompleted run reads", async () => {
    const { store, tasks, vcs } = makeMocks();
    const run = makeRun({ id: "run-lookup", task_id: "task-lookup" });
    const runLookup = {
      getRun: vi.fn().mockResolvedValue(run),
      getRunsByStatus: vi.fn().mockResolvedValue([]),
      getRunsByStatuses: vi.fn().mockResolvedValue([]),
      getRunsByBaseBranch: vi.fn().mockResolvedValue([]),
    };
    store.getRun.mockImplementation(() => {
      throw new Error("local getRun should not be used");
    });

    const refinery = new Refinery(store as any, tasks as any, "/tmp/project", vcs, {
      runLookup,
      registeredProjectId: "proj-1",
    });

    const report = await refinery.mergeCompleted({
      runId: run.id,
      runTests: false,
      projectId: "proj-1",
      taskId: run.task_id,
    });

    expect(runLookup.getRun).toHaveBeenCalledWith("run-lookup");
    expect(report.merged).toHaveLength(1);
  });

  it("closes registered native tasks via Postgres instead of the local tasks table", async () => {
    const { store, tasks, vcs, mockDb } = makeMocks();
    const run = makeRun({ id: "run-pg-task", task_id: "task-pg-task" });
    const runLookup = {
      getRun: vi.fn().mockResolvedValue(run),
      getRunsByStatus: vi.fn().mockResolvedValue([run]),
      getRunsByStatuses: vi.fn().mockResolvedValue([run]),
      getRunsByBaseBranch: vi.fn().mockResolvedValue([]),
    };
    mockPostgresListTasks.mockResolvedValue([{ id: "task-1" }]);

    const refinery = new Refinery(store as any, tasks as any, "/tmp/project", vcs, {
      runLookup,
      registeredProjectId: "proj-1",
    });

    await refinery.mergeCompleted({ runId: run.id, runTests: false, projectId: "proj-1", taskId: run.task_id });

    expect(mockPostgresListTasks).toHaveBeenCalledWith("proj-1", { runId: "run-pg-task", limit: 1 });
    expect(mockPostgresUpdateTask).toHaveBeenCalledWith("proj-1", "task-1", { status: "merged" });
    expect(mockDb.prepare).not.toHaveBeenCalled();
  });

  it("uses Postgres-first run updates and events for registered finalize PR writes", async () => {
    const { store, tasks, vcs } = makeMocks();
    const run = makeRun({ id: "run-registered-pr", task_id: "task-registered-pr" });
    const { refinery } = makeRegisteredRefinery(store, tasks, vcs, run);

    store.getRun.mockImplementation(() => {
      throw new Error("local run lookup should not be used for registered writes");
    });

    const result = await refinery.ensurePullRequestForRun({
      runId: run.id,
      baseBranch: "main",
      updateRunStatus: true,
    });

    expect(result.prUrl).toBe("foreman://pr/task-registered-pr");
    expect(mockPostgresLogEvent).toHaveBeenCalledWith(
      "proj-1",
      run.id,
      "pr-created",
      expect.any(String),
    );
    expect(mockPostgresUpdateRun).toHaveBeenCalledWith(
      "proj-1",
      run.id,
      { status: "pr-created" },
    );
    expect(store.logEvent).not.toHaveBeenCalled();
    expect(store.updateRun).not.toHaveBeenCalled();
  });

  it("falls back to the local store when registered run persistence fails", async () => {
    const { store, tasks, vcs } = makeMocks();
    const run = makeRun({ id: "run-registered-fallback", task_id: "task-registered-fallback" });
    const { refinery } = makeRegisteredRefinery(store, tasks, vcs, run);

    mockPostgresLogEvent.mockRejectedValueOnce(new Error("pg event unavailable"));
    mockPostgresUpdateRun.mockRejectedValueOnce(new Error("pg update unavailable"));

    const result = await refinery.ensurePullRequestForRun({
      runId: run.id,
      baseBranch: "main",
      updateRunStatus: true,
    });

    expect(result.prUrl).toBe("foreman://pr/task-registered-fallback");
    expect(store.logEvent).toHaveBeenCalledWith(
      run.project_id,
      "pr-created",
      expect.objectContaining({ taskId: run.task_id, existing: false }),
      run.id,
    );
    expect(store.updateRun).toHaveBeenCalledWith(run.id, { status: "pr-created" });
  });

  it("keeps unregistered refinery writes local-only", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-local-pr", task_id: "task-local-pr" });
    store.getRun.mockReturnValue(run);

    const result = await refinery.ensurePullRequestForRun({
      runId: run.id,
      baseBranch: "main",
      updateRunStatus: true,
    });

    expect(result.prUrl).toBe("foreman://pr/task-local-pr");
    expect(store.updateRun).toHaveBeenCalledWith(run.id, { status: "pr-created" });
    expect(store.logEvent).toHaveBeenCalledWith(
      run.project_id,
      "pr-created",
      expect.objectContaining({ taskId: run.task_id, existing: false }),
      run.id,
    );
    expect(mockPostgresUpdateRun).not.toHaveBeenCalled();
    expect(mockPostgresLogEvent).not.toHaveBeenCalled();
  });

  it("preserves a registered pr-created run instead of downgrading it to failed", async () => {
    const { store, tasks, vcs } = makeMocks();
    const run = makeRun({ id: "run-registered-keep", task_id: "task-registered-keep" });
    const { refinery } = makeRegisteredRefinery(store, tasks, vcs, run);
    mockPostgresGetRun.mockResolvedValueOnce({ id: run.id, status: "pr-created" });

    await (refinery as any).persistRunUpdate(run, { status: "failed" });

    expect(mockPostgresUpdateRun).not.toHaveBeenCalled();
    expect(store.updateRun).not.toHaveBeenCalled();
  });

  it("preserves a local merged run instead of downgrading it to conflict", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-local-keep", task_id: "task-local-keep" });
    store.getRun.mockReturnValue({ ...run, status: "merged" });

    await (refinery as any).persistRunUpdate(run, { status: "conflict" });

    expect(store.updateRun).not.toHaveBeenCalled();
  });

  it("uses branch: label from bead as target branch instead of default", async () => {
    const { store, tasks, refinery, vcs } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);
    (removeWorktree as any).mockResolvedValue(undefined);

    // Mock tasks.show to return a bead with a branch: label
    tasks.show.mockResolvedValue({
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
      "foreman/task-abc",
      "installer",
    );
  });

  it("falls back to default branch when bead has no branch: label", async () => {
    const { store, tasks, refinery, vcs } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);
    (removeWorktree as any).mockResolvedValue(undefined);

    // Mock tasks.show to return a bead with no branch: label
    tasks.show.mockResolvedValue({
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
    // resetTaskToOpen must be called so the task reappears in the ready queue
    expect(enqueueResetTaskToOpen).not.toHaveBeenCalled();
  });

  it("adds failure note when code-conflict PR creation fails", async () => {
    const { store, tasks, refinery } = makeMocks();
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
      expect.anything(), run.task_id, expect.stringContaining("manual retry required"), "refinery",
    );
  });

  it("adds failure note when rebase-conflict PR creation fails", async () => {
    const { store, tasks, refinery } = makeMocks({
      rebaseBranch: vi.fn().mockResolvedValue({
        success: false,
        hasConflicts: true,
        conflictingFiles: ["src/index.ts"],
      }),
      getConflictingFiles: vi.fn().mockResolvedValue(["src/index.ts"]),
      abortRebase: vi.fn().mockResolvedValue(undefined),
    });
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);

    // Sequence after VcsBackend migration:
    //   1. rebaseBranch() → conflict result
    //   2. abortRebase()  → success
    //   3. push()         → success
    //   4. gh pr create   → fails (gh not available)
    // → createPrForConflict returns null → addFailureNote must be called
    (execFile as any).mockImplementation(
      (cmd: string, args: string[], _opts: any, callback: Function) => {
        if (cmd === "gh") {
          const err = new Error("gh not available") as any;
          err.stdout = "";
          err.stderr = "gh not available";
          callback(err);
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
      expect.anything(), run.task_id, expect.stringContaining("manual retry required"), "refinery",
    );
  });

  it("marks run as test-failed when tests fail after merge", async () => {
    const { store, tasks, refinery } = makeMocks();
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
    expect(report.testFailures[0].taskId).toBe(run.task_id);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "test-failed" }),
    );
    expect(enqueueAddNotesToBead).toHaveBeenCalledWith(
      expect.anything(), run.task_id, expect.stringContaining("tests failed"), "refinery",
    );
  });

  it("merges in dependency order", async () => {
    const { store, tasks, refinery } = makeMocks();
    const runA = makeRun({ id: "run-a", task_id: "task-a" });
    const runB = makeRun({ id: "run-b", task_id: "task-b" });
    store.getRunsByStatus.mockReturnValue([runB, runA]); // B first (wrong order)
    // task-b depends on task-a — so task-a should merge first
    (tasks.getGraph as any).mockResolvedValue({
      nodes: [],
      edges: [{ from: "task-b", to: "task-a", type: "blocks" }],
    });
    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(2);
    // task-a (dependency) should merge first
    expect(report.merged[0].taskId).toBe("task-a");
    expect(report.merged[1].taskId).toBe("task-b");
  });

  it("applies taskId filter when provided", async () => {
    const { store, refinery } = makeMocks();
    const runA = makeRun({ id: "run-a", task_id: "task-target" });
    const runB = makeRun({ id: "run-b", task_id: "task-other" });
    // When taskId is specified, getCompletedRuns uses getRunsByStatuses (not getRunsByStatus)
    store.getRunsByStatuses.mockReturnValue([runA, runB]);
    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false, taskId: "task-target" });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].taskId).toBe("task-target");
  });

  it("catches unexpected errors and puts run in unexpectedErrors (not testFailures)", async () => {
    const { store, tasks, refinery } = makeMocks();
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
      expect.anything(), run.task_id, expect.stringContaining("Merge failed"), "refinery",
    );
  });

  it("syncs registered native task status when merge marks run failed", async () => {
    const { store, tasks, vcs } = makeMocks();
    const run = makeRun({ id: "run-pg-fail", task_id: "task-pg-fail" });
    const { refinery } = makeRegisteredRefinery(store, tasks, vcs, run);

    (refinery as any).vcsBackend.mergeWithoutCommit = vi
      .fn()
      .mockRejectedValue(new Error("Unexpected git failure"));

    const report = await refinery.mergeCompleted({
      runId: run.id,
      runTests: false,
      projectId: "proj-1",
      taskId: run.task_id,
    });

    expect(report.unexpectedErrors).toHaveLength(1);
    expect(mockPostgresUpdateRun).toHaveBeenCalledWith("proj-1", run.id, { status: "failed" });
    expect(mockPostgresUpdateTaskStatusForRun).toHaveBeenCalledWith("proj-1", run.id, "failed");
  });

  it("retries a previously-failed task: finds run in test-failed state when taskId is specified", async () => {
    // Reproduces: "no completed run found for task <taskid>" after a failed merge.
    // When --bead is supplied, getCompletedRuns() must also look in terminal failure
    // states so the user can retry without manually resetting the run.
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-retry", task_id: "task-retry", status: "test-failed" });

    // Normal getRunsByStatus("completed") returns nothing (the run is test-failed)
    store.getRunsByStatus.mockReturnValue([]);
    // getRunsByStatuses with the retry-eligible statuses returns the failed run
    store.getRunsByStatuses.mockReturnValue([run]);

    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false, taskId: "task-retry" });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].taskId).toBe("task-retry");
    // Confirm getRunsByStatuses was called (not just getRunsByStatus)
    expect(store.getRunsByStatuses).toHaveBeenCalled();
  });

  it("retries a previously-failed task: finds run in conflict state when taskId is specified", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-conflict-retry", task_id: "task-conflict", status: "conflict" });

    store.getRunsByStatus.mockReturnValue([]);
    store.getRunsByStatuses.mockReturnValue([run]);

    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false, taskId: "task-conflict" });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].taskId).toBe("task-conflict");
  });

  it("prefers completed run over newer stuck run when both exist for same task", async () => {
    // Reproduces: two runs for dashboard-g7l — stuck (created later) and completed (created earlier).
    // getRunsByStatuses returns both; we must use the completed one.
    const { store, refinery } = makeMocks();
    const completedRun = makeRun({ id: "run-old-completed", task_id: "task-dup", status: "completed" });
    const stuckRun = makeRun({ id: "run-new-stuck", task_id: "task-dup", status: "failed" });

    store.getRunsByStatus.mockReturnValue([]);
    // Postgres returns stuck first (most recent created_at DESC)
    store.getRunsByStatuses.mockReturnValue([stuckRun, completedRun]);

    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false, taskId: "task-dup" });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].taskId).toBe("task-dup");
    // Must have used the completed run, not the stuck one
    expect(report.merged[0].runId).toBe("run-old-completed");
  });

  it("without taskId filter, only looks for completed runs (no retry expansion)", async () => {
    const { store, refinery } = makeMocks();
    store.getRunsByStatus.mockReturnValue([]);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(0);
    // getRunsByStatuses should NOT be called when no taskId filter is active
    expect(store.getRunsByStatuses).not.toHaveBeenCalled();
  });

  // ── bead close-after-merge tests (bd-jpt4 fix) ───────────────────────────

  it("calls closeTask after successful merge in mergeCompleted()", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ task_id: "task-closeme" });
    store.getRunsByStatus.mockReturnValue([run]);
    (removeWorktree as any).mockResolvedValue(undefined);

    await refinery.mergeCompleted({ runTests: false });

    expect(enqueueCloseTask).toHaveBeenCalledWith(expect.anything(), "task-closeme", "refinery");
  });

  it("does NOT call closeTask when merge has code conflicts", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ task_id: "task-conflict" });
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
    expect(enqueueCloseTask).not.toHaveBeenCalled();
  });

  it("does NOT call closeTask when tests fail after merge in mergeCompleted()", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ task_id: "task-testfail" });
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
    expect(enqueueCloseTask).not.toHaveBeenCalled();
  });

  // ── Race condition fix: overrideRun bypasses query ─────────────────────────

  it("uses overrideRun to bypass query entirely when provided", async () => {
    // This tests the fix for the auto-merge race condition where finalize marks
    // a run as completed but the query hasn't seen the update yet.
    // Using overrideRun bypasses the getCompletedRuns() query entirely.
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-override", task_id: "task-override", status: "completed" });

    // getRunsByStatuses returns nothing (race condition scenario)
    store.getRunsByStatuses.mockReturnValue([]);
    (removeWorktree as any).mockResolvedValue(undefined);

    // Pass overrideRun directly - this bypasses the query
    const report = await refinery.mergeCompleted({
      runTests: false,
      projectId: "proj-1",
      taskId: "task-override",
      overrideRun: run,
    });

    // Should successfully find and merge the run via overrideRun
    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].taskId).toBe("task-override");
    // getRunsByStatuses should NOT be called when overrideRun is provided
    expect(store.getRunsByStatuses).not.toHaveBeenCalled();
  });

  it("does NOT call getRunsByStatuses when overrideRun is provided", async () => {
    // When overrideRun is provided, the normal query should be skipped entirely
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-skip-query", task_id: "task-skip-query", status: "completed" });

    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({
      runTests: false,
      taskId: "task-skip-query",
      overrideRun: run,
    });

    expect(report.merged).toHaveLength(1);
    // getRunsByStatuses should NOT be called when overrideRun is provided
    expect(store.getRunsByStatuses).not.toHaveBeenCalled();
    // getRunsByStatuses should stay bypassed when overrideRun is provided.
    // store.getRun may still be consulted by later persistence helpers.
  });

  it("skips query and uses overrideRun even when taskId differs", async () => {
    // When overrideRun is provided, the taskId parameter is still used for
    // other purposes (like target branch resolution), but the run lookup is
    // bypassed entirely.
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-task-a", task_id: "task-a", status: "completed" });

    // getRunsByStatuses returns nothing
    store.getRunsByStatuses.mockReturnValue([]);
    (removeWorktree as any).mockResolvedValue(undefined);

    // taskId differs from run's task_id, but overrideRun bypasses the check
    const report = await refinery.mergeCompleted({
      runTests: false,
      taskId: "task-b",
      overrideRun: run,
    });

    // Should still merge because overrideRun bypasses taskId matching
    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].taskId).toBe("task-a");
  });
});

describe("Refinery.createPRs()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("uses the injected registered lookup for completed runs", async () => {
    const { store, tasks, vcs } = makeMocks();
    const run = makeRun({ id: "run-pr-registered", task_id: "task-pr-registered" });
    const { refinery, runLookup } = makeRegisteredRefinery(store, tasks, vcs, run);

    store.getRunsByStatus.mockImplementation(() => {
      throw new Error("local getRunsByStatus should not be used");
    });

    const report = await refinery.createPRs({ projectId: "proj-1" });

    expect(runLookup.getRunsByStatus).toHaveBeenCalledWith("completed", "proj-1");
    expect(store.getRunsByStatus).not.toHaveBeenCalled();
    expect(report.created).toHaveLength(1);
  });

  it("keeps local completed-run lookup unchanged", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-pr-local", task_id: "task-pr-local" });
    store.getRunsByStatus.mockReturnValue([run]);

    const report = await refinery.createPRs();

    expect(store.getRunsByStatus).toHaveBeenCalledWith("completed");
    expect(store.getRunsByStatuses).not.toHaveBeenCalled();
    expect(report.created).toHaveLength(1);
  });
});

// ── resolveConflict() bead close tests (bd-jpt4 fix) ─────────────────────────

describe("Refinery.resolveConflict() — bead close after merge", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("calls closeTask after successful resolveConflict (theirs)", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", task_id: "task-resolve", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    const result = await refinery.resolveConflict("run-1", "theirs", { runTests: false });

    expect(result).toBe(true);
    expect(enqueueCloseTask).toHaveBeenCalledWith(expect.anything(), "task-resolve", "refinery");
  });

  it("does NOT call closeTask when resolveConflict uses abort strategy", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", task_id: "task-abort", status: "conflict" });
    store.getRun.mockReturnValue(run);

    const result = await refinery.resolveConflict("run-1", "abort");

    expect(result).toBe(false);
    expect(enqueueCloseTask).not.toHaveBeenCalled();
  });

  it("does NOT call closeTask when resolveConflict git merge fails", async () => {
    const { store, refinery } = makeMocks({
      mergeWithStrategy: vi.fn().mockResolvedValue({ success: false, conflicts: ["README.md"] }),
      abortMerge: vi.fn().mockResolvedValue(undefined),
    });
    const run = makeRun({ id: "run-1", task_id: "task-mergefail", status: "conflict" });
    store.getRun.mockReturnValue(run);

    const result = await refinery.resolveConflict("run-1", "theirs");

    expect(result).toBe(false);
    expect(enqueueCloseTask).not.toHaveBeenCalled();
  });

  it("does NOT call closeTask when tests fail after resolveConflict merge", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", task_id: "task-testfail-resolve", status: "conflict" });
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
    expect(enqueueCloseTask).not.toHaveBeenCalled();
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
    const { tasks, refinery } = makeMocks();
    tasks.getGraph.mockRejectedValue(new Error("No graph"));
    const runA = makeRun({ id: "run-a", task_id: "task-a" });
    const runB = makeRun({ id: "run-b", task_id: "task-b" });

    const result = await refinery.orderByDependencies([runA, runB]);
    expect(result).toEqual([runA, runB]);
  });

  it("places dependency before dependent", async () => {
    const { tasks, refinery } = makeMocks();
    (tasks.getGraph as any).mockResolvedValue({
      nodes: [],
      edges: [{ from: "task-b", to: "task-a", type: "blocks" }], // task-b depends on task-a
    });
    const runA = makeRun({ id: "run-a", task_id: "task-a" });
    const runB = makeRun({ id: "run-b", task_id: "task-b" });

    const result = await refinery.orderByDependencies([runB, runA]);
    expect(result[0].task_id).toBe("task-a");
    expect(result[1].task_id).toBe("task-b");
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
    const tasks = {
      getGraph: vi.fn(async () => ({ edges: [] })),
      show: vi.fn(async () => null),
      update: vi.fn(async () => undefined),
    };
    const vcs = makeMockVcs();
    const refinery = new Refinery(store as any, tasks as any, "/tmp/project", vcs);
    return { store, tasks, refinery, vcs, mockDb };
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
    const tasks = {
      getGraph: vi.fn(async () => ({ edges: [] })),
      show: vi.fn(async () => null),
      update: vi.fn(async () => undefined),
    };
    const vcs = makeMockVcs();
    const refinery = new Refinery(store as any, tasks as any, "/tmp/project", vcs);
    return { store, tasks, refinery, vcs, mockDb };
  }

  describe("mergeCompleted()", () => {
    it("calls taskStore.updateStatus with 'merged' when a native task exists for the run", async () => {
      const { store, refinery } = makeMocksWithTask("run-task-1", "task-abc");
      const run = makeRun({ id: "run-task-1", task_id: "task-task-1" });
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
      const run = makeRun({ id: "run-task-2", task_id: "task-task-2" });
      store.getRunsByStatus.mockReturnValue([run]);
      (removeWorktree as any).mockResolvedValue(undefined);

      const taskStore = (refinery as any).taskStore;
      vi.spyOn(taskStore, "updateStatus").mockImplementation(() => {
        throw new Error("updateStatus failed");
      });

      // Should not throw — closeNativeTaskPostMerge is non-fatal
      await expect(refinery.mergeCompleted({ runTests: false })).resolves.not.toThrow();
    });

    it("still calls enqueueCloseTask when no native task exists for the run", async () => {
      const { store, refinery } = makeMocksWithoutTask();
      const run = makeRun({ id: "run-no-task", task_id: "task-no-task" });
      store.getRunsByStatus.mockReturnValue([run]);
      (removeWorktree as any).mockResolvedValue(undefined);

      // Reset spy before the call
      (syncBeadStatusAfterMerge as any).mockClear();

      await refinery.mergeCompleted({ runTests: false });

      // enqueueCloseTask should still be called for the task
      expect(enqueueCloseTask).toHaveBeenCalledWith(expect.anything(), "task-no-task", "refinery");

      // syncBeadStatusAfterMerge should NOT be called (beads fallback removed)
      expect(syncBeadStatusAfterMerge).not.toHaveBeenCalled();
    });
  });

  describe("resolveConflict()", () => {
    it("calls taskStore.updateStatus with 'merged' when a native task exists for the run", async () => {
      const { store, refinery } = makeMocksWithTask("run-conflict-task", "task-xyz");
      const run = makeRun({ id: "run-conflict-task", task_id: "task-conflict-task", status: "conflict" });
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
      const run = makeRun({ id: "run-conflict-task-2", task_id: "task-conflict-task-2", status: "conflict" });
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
