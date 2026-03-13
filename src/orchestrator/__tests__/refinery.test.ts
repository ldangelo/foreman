import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";

// ── Module mocks ─────────────────────────────────────────────────────────────

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

vi.mock("../../lib/git.js", () => ({
  mergeWorktree: vi.fn(),
  removeWorktree: vi.fn(),
}));

// Import mocked modules AFTER vi.mock declarations
import { execFile } from "node:child_process";
import { mergeWorktree, removeWorktree } from "../../lib/git.js";
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
    tmux_session: null,
    ...overrides,
  };
}

function makeMocks() {
  const store = {
    getRunsByStatus: vi.fn(() => [] as Run[]),
    getRun: vi.fn(() => null as Run | null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
  };
  const seeds = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
  };
  const refinery = new Refinery(store as any, seeds as any, "/tmp/project");
  return { store, seeds, refinery };
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
    const { store, refinery } = makeMocks();
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
    const { store, refinery } = makeMocks();
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

    const result = await refinery.resolveConflict("run-1", "theirs");

    expect(result).toBe(false);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "failed" }),
    );

    // Ensure git merge --abort is called to leave the repo in a clean state
    const calls: string[][] = (execFile as any).mock.calls.map((c: any[]) => c[1]);
    const abortCall = calls.find((args) => Array.isArray(args) && args.includes("--abort"));
    expect(abortCall).toBeDefined();
  });

  it("theirs strategy uses provided targetBranch in git checkout", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    await refinery.resolveConflict("run-1", "theirs", { targetBranch: "develop", runTests: false });

    const calls: string[][] = (execFile as any).mock.calls.map((c: any[]) => c[1]);
    const checkoutCall = calls.find((args) => Array.isArray(args) && args[0] === "checkout");
    expect(checkoutCall).toEqual(["checkout", "develop"]);
  });

  it("theirs strategy defaults to main when no targetBranch provided", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    await refinery.resolveConflict("run-1", "theirs", { runTests: false });

    const calls: string[][] = (execFile as any).mock.calls.map((c: any[]) => c[1]);
    const checkoutCall = calls.find((args) => Array.isArray(args) && args[0] === "checkout");
    expect(checkoutCall).toEqual(["checkout", "main"]);
  });

  it("theirs strategy marks run as test-failed and reverts when tests fail after merge", async () => {
    const { store, refinery } = makeMocks();
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
    const { store, refinery } = makeMocks();
    const run = makeRun({ id: "run-1", status: "conflict", worktree_path: "/tmp/worktrees/seed-abc" });
    store.getRun.mockReturnValue(run);

    (execFile as any).mockImplementation(
      (_cmd: string, _args: string[], _opts: any, callback: Function) => {
        callback(null, { stdout: "", stderr: "" });
      },
    );
    (removeWorktree as any).mockResolvedValue(undefined);

    await refinery.resolveConflict("run-1", "theirs");

    expect(removeWorktree).toHaveBeenCalledWith("/tmp/project", "/tmp/worktrees/seed-abc");
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
    (mergeWorktree as any).mockResolvedValue({ success: true });
    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].seedId).toBe(run.seed_id);
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "merged" }),
    );
  });

  it("marks run as conflict when merge has conflicts", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);
    (mergeWorktree as any).mockResolvedValue({
      success: false,
      conflicts: ["README.md", "src/index.ts"],
    });

    // git calls succeed, but gh (PR creation) fails so we fall back to conflict reporting
    (execFile as any).mockImplementation(
      (cmd: string, _args: string[], _opts: any, callback: Function) => {
        if (cmd === "gh") {
          const err = new Error("gh not available") as any;
          err.stdout = "";
          err.stderr = "gh not available";
          callback(err);
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.conflicts).toHaveLength(1);
    expect(report.conflicts[0].conflictFiles).toContain("README.md");
    expect(store.updateRun).toHaveBeenCalledWith(
      run.id,
      expect.objectContaining({ status: "conflict" }),
    );
  });

  it("marks run as test-failed when tests fail after merge", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);
    (mergeWorktree as any).mockResolvedValue({ success: true });

    // First call for tests (npm test), fails; second call for git reset, succeeds
    let callCount = 0;
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        callCount++;
        if (args.includes("test") || _cmd.includes("npm")) {
          // Test command failure
          const err = new Error("Tests failed") as any;
          err.stdout = "FAIL src/foo.test.ts";
          err.stderr = "Tests failed";
          callback(err);
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
    (mergeWorktree as any).mockResolvedValue({ success: true });
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
    store.getRunsByStatus.mockReturnValue([runA, runB]);
    (mergeWorktree as any).mockResolvedValue({ success: true });
    (removeWorktree as any).mockResolvedValue(undefined);

    const report = await refinery.mergeCompleted({ runTests: false, seedId: "seed-target" });

    expect(report.merged).toHaveLength(1);
    expect(report.merged[0].seedId).toBe("seed-target");
  });

  it("catches unexpected errors and puts run in testFailures", async () => {
    const { store, refinery } = makeMocks();
    const run = makeRun();
    store.getRunsByStatus.mockReturnValue([run]);
    (mergeWorktree as any).mockRejectedValue(new Error("Unexpected git failure"));

    const report = await refinery.mergeCompleted({ runTests: false });

    expect(report.testFailures).toHaveLength(1);
    expect(report.testFailures[0].error).toContain("Unexpected git failure");
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
