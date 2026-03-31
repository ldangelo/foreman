/**
 * Tests for Refinery.rebaseStackedBranches() — rebases stacked branches onto
 * main after their base dependency branch is merged.
 *
 * rebaseStackedBranches() is private, so we test it indirectly by calling
 * mergeCompleted() in scenarios where stacked runs exist.
 */
import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";

// ── Module mocks ─────────────────────────────────────────────────────────────
// NOTE: This suite intentionally exercises the lib/git.js compatibility shim
// directly (mergeWorktree/removeWorktree/gitBranchExists), so it should remain
// on the shim until that compatibility surface is explicitly retired.

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
  enqueueResetSeedToOpen: vi.fn(),
  enqueueCloseSeed: vi.fn(),
}));

// Imports after mocks
import { execFile } from "node:child_process";
import { mergeWorktree, removeWorktree, gitBranchExists } from "../../lib/git.js";
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

function makeMocks(stackedRuns: Run[] = []) {
  const store = {
    getRunsByStatus: vi.fn(() => [] as Run[]),
    getRunsByStatuses: vi.fn(() => [] as Run[]),
    getRun: vi.fn(() => null as Run | null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRunsByBaseBranch: vi.fn(() => stackedRuns),
  };
  const seeds = {
    getGraph: vi.fn(async () => ({ edges: [] })),
    show: vi.fn(async () => null),
    update: vi.fn(async () => undefined),
  };
  const refinery = new Refinery(store as any, seeds as any, "/tmp/project");
  return { store, seeds, refinery };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Refinery.rebaseStackedBranches() (via mergeCompleted)", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("calls getRunsByBaseBranch with the merged branch name after a successful merge", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const { store, refinery } = makeMocks([]); // no stacked runs
    store.getRunsByStatus.mockReturnValue([mergedRun]);
    (mergeWorktree as any).mockResolvedValue({ success: true });
    (removeWorktree as any).mockResolvedValue(undefined);
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    await refinery.mergeCompleted({ runTests: false });

    expect(store.getRunsByBaseBranch).toHaveBeenCalledWith("foreman/story-1");
  });

  it("rebases stacked branches onto target after merge — calls git rebase --onto", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const stackedRun = makeRun({
      id: "run-2",
      seed_id: "story-2",
      status: "running",
      base_branch: "foreman/story-1",
    });
    const { store, refinery } = makeMocks([stackedRun]);
    store.getRunsByStatus.mockReturnValue([mergedRun]);
    (mergeWorktree as any).mockResolvedValue({ success: true });
    (removeWorktree as any).mockResolvedValue(undefined);
    (gitBranchExists as any).mockResolvedValue(true); // stacked branch exists

    const gitCalls: string[][] = [];
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args)) gitCalls.push(args);
        if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    await refinery.mergeCompleted({ runTests: false });

    // Should have issued git rebase --onto main foreman/story-1 foreman/story-2
    const rebaseOntoCall = gitCalls.find(
      (args) =>
        args[0] === "rebase" &&
        args.includes("--onto") &&
        args.includes("main") &&
        args.includes("foreman/story-1") &&
        args.includes("foreman/story-2"),
    );
    expect(rebaseOntoCall).toBeDefined();
  });

  it("skips rebasing stacked run when its branch does not exist locally", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const stackedRun = makeRun({
      id: "run-2",
      seed_id: "story-2",
      status: "running",
      base_branch: "foreman/story-1",
    });
    const { store, refinery } = makeMocks([stackedRun]);
    store.getRunsByStatus.mockReturnValue([mergedRun]);
    (mergeWorktree as any).mockResolvedValue({ success: true });
    (removeWorktree as any).mockResolvedValue(undefined);
    // gitBranchExists mock is no longer called; VcsBackend.branchExists() is used instead.
    // Make execFile throw for "show-ref" calls so GitBackend.branchExists() returns false.
    const gitCalls: string[][] = [];
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args)) gitCalls.push(args);
        if (Array.isArray(args) && args[0] === "show-ref") {
          // Simulate branch not existing — GitBackend.branchExists() catches this and returns false
          callback(new Error("fatal: not a valid ref"), { stdout: "", stderr: "" });
        } else if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const report = await refinery.mergeCompleted({ runTests: false });

    // Merge should still succeed even though rebase was skipped
    expect(report.merged).toHaveLength(1);

    const rebaseOntoCall = gitCalls.find(
      (args) => args[0] === "rebase" && args.includes("--onto"),
    );
    expect(rebaseOntoCall).toBeUndefined();
  });

  it("skips rebasing stacked runs with terminal statuses (merged, failed)", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    // This stacked run is already merged — should not be rebased
    const stackedRun = makeRun({
      id: "run-2",
      seed_id: "story-2",
      status: "merged",
      base_branch: "foreman/story-1",
    });
    const { store, refinery } = makeMocks([stackedRun]);
    store.getRunsByStatus.mockReturnValue([mergedRun]);
    (mergeWorktree as any).mockResolvedValue({ success: true });
    (removeWorktree as any).mockResolvedValue(undefined);
    (gitBranchExists as any).mockResolvedValue(true); // branch exists

    const gitCalls: string[][] = [];
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args)) gitCalls.push(args);
        if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const report = await refinery.mergeCompleted({ runTests: false });

    // Merge should succeed
    expect(report.merged).toHaveLength(1);

    const rebaseOntoCall = gitCalls.find(
      (args) => args[0] === "rebase" && args.includes("--onto"),
    );
    expect(rebaseOntoCall).toBeUndefined();
  });

  it("merge succeeds even if rebase of stacked branch fails", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const stackedRun = makeRun({
      id: "run-2",
      seed_id: "story-2",
      status: "running",
      base_branch: "foreman/story-1",
    });
    const { store, refinery } = makeMocks([stackedRun]);
    store.getRunsByStatus.mockReturnValue([mergedRun]);
    (mergeWorktree as any).mockResolvedValue({ success: true });
    (removeWorktree as any).mockResolvedValue(undefined);
    (gitBranchExists as any).mockResolvedValue(true);

    // rebase --onto fails; rebase --abort succeeds
    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args) && args[0] === "rebase" && args.includes("--onto")) {
          const err = new Error("rebase conflict") as any;
          err.stdout = "";
          err.stderr = "CONFLICT during rebase";
          callback(err);
        } else if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    const report = await refinery.mergeCompleted({ runTests: false });

    // Merge itself must still succeed (rebase failure is non-fatal)
    expect(report.merged).toHaveLength(1);
    expect(report.testFailures).toHaveLength(0);
  });

  it("updates base_branch to null in store when rebase succeeds", async () => {
    const mergedRun = makeRun({ seed_id: "story-1", status: "completed" });
    const stackedRun = makeRun({
      id: "run-2",
      seed_id: "story-2",
      status: "running",
      base_branch: "foreman/story-1",
    });
    const { store, refinery } = makeMocks([stackedRun]);
    store.getRunsByStatus.mockReturnValue([mergedRun]);
    (mergeWorktree as any).mockResolvedValue({ success: true });
    (removeWorktree as any).mockResolvedValue(undefined);
    (gitBranchExists as any).mockResolvedValue(true);

    (execFile as any).mockImplementation(
      (_cmd: string, args: string[], _opts: any, callback: Function) => {
        if (Array.isArray(args) && args[0] === "log") {
          callback(null, { stdout: "abc1234 commit\n", stderr: "" });
        } else {
          callback(null, { stdout: "", stderr: "" });
        }
      },
    );

    await refinery.mergeCompleted({ runTests: false });

    // After successful rebase, base_branch should be cleared
    expect(store.updateRun).toHaveBeenCalledWith(
      "run-2",
      expect.objectContaining({ base_branch: null }),
    );
  });
});
