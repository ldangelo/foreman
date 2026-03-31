/**
 * Tests for per-seed branch: label support in Refinery.mergeCompleted().
 *
 * Verifies that:
 * 1. When a bead has branch:installer, it merges into installer, not main
 * 2. When no branch: label, falls back to the default target branch
 * 3. Each run can target a different branch (per-run resolution)
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import type { Run } from "../../lib/store.js";
import type { VcsBackend } from "../../lib/vcs/index.js";

// ── Module mocks ─────────────────────────────────────────────────────────────

vi.mock("node:child_process", () => ({
  execFile: vi.fn(),
}));

vi.mock("../task-backend-ops.js", () => ({
  enqueueResetSeedToOpen: vi.fn().mockResolvedValue(undefined),
  enqueueCloseSeed: vi.fn().mockResolvedValue(undefined),
  enqueueAddNotesToBead: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("../../lib/archive-reports.js", () => ({
  archiveWorktreeReports: vi.fn().mockResolvedValue(undefined),
  REPORT_FILES: [
    "EXPLORER_REPORT.md", "DEVELOPER_REPORT.md", "QA_REPORT.md",
    "REVIEW.md", "FINALIZE_REPORT.md", "TASK.md", "AGENTS.md", "BLOCKED.md",
    "SESSION_LOG.md", "RUN_LOG.md",
  ],
}));

import { execFile } from "node:child_process";
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

/** Mock execFile: git log returns a commit (so "no commits" guard passes), all else succeeds. */
function mockExecFileDefault() {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  (execFile as any).mockImplementation(
    (cmd: string, args: string[], _opts: unknown, callback: (err: null | Error, result?: { stdout: string; stderr: string }) => void) => {
      if (cmd === "git" && Array.isArray(args) && args[0] === "log") {
        callback(null, { stdout: "abc1234 some commit\n", stderr: "" });
      } else {
        callback(null, { stdout: "", stderr: "" });
      }
    },
  );
}

/** Create a minimal mock VcsBackend with vcs.merge() succeeding by default. */
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
    commit: vi.fn().mockResolvedValue(undefined),
    push: vi.fn().mockResolvedValue(undefined),
    pull: vi.fn().mockResolvedValue(undefined),
    rebase: vi.fn().mockResolvedValue({ success: true, hasConflicts: false }),
    abortRebase: vi.fn().mockResolvedValue(undefined),
    merge: vi.fn().mockResolvedValue({ success: true }),
    mergeWithoutCommit: vi.fn().mockResolvedValue({ success: true }),
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
      rebaseCommand: "git pull --rebase origin",
      branchVerifyCommand: "git rev-parse --abbrev-ref HEAD",
      cleanCommand: "git clean -fd",
    }),
    ...overrides,
  } as VcsBackend;
}

function makeMocks(seedLabels: string[] = []) {
  const store = {
    getRunsByStatus: vi.fn().mockReturnValue([] as Run[]),
    getRunsByStatuses: vi.fn().mockReturnValue([] as Run[]),
    getRun: vi.fn().mockReturnValue(null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getRunsByBaseBranch: vi.fn().mockReturnValue([] as Run[]),
    sendMessage: vi.fn(),
  };
  const seeds = {
    getGraph: vi.fn().mockResolvedValue({ edges: [] }),
    show: vi.fn().mockResolvedValue({
      status: "open",
      title: "Test Seed",
      description: "A test",
      labels: seedLabels,
    }),
    update: vi.fn().mockResolvedValue(undefined),
  };
  return { store, seeds };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("Refinery — branch label targeting", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mockExecFileDefault();
  });

  it("uses branch: label as merge target instead of default", async () => {
    const run = makeRun();
    const { store, seeds } = makeMocks(["branch:installer"]);
    store.getRunsByStatus = vi.fn().mockReturnValue([run]);

    const vcs = makeMockVcs();
    const refinery = new Refinery(store as never, seeds as never, "/tmp", vcs);
    await refinery.mergeCompleted({ targetBranch: "main", runTests: false });

    // checkoutBranch should be called with "installer" (from branch: label), not "main"
    expect(vcs.checkoutBranch).toHaveBeenCalledWith("/tmp", "installer");
    // Squash-merge flow is now backend-driven; verify the branch merge targeted installer.
    expect(vcs.mergeWithoutCommit).toHaveBeenCalledWith("/tmp", "foreman/seed-abc", "installer");
  });

  it("falls back to default target when no branch: label exists", async () => {
    const run = makeRun();
    const { store, seeds } = makeMocks([]); // no branch: label
    store.getRunsByStatus = vi.fn().mockReturnValue([run]);

    const vcs = makeMockVcs();
    const refinery = new Refinery(store as never, seeds as never, "/tmp", vcs);
    await refinery.mergeCompleted({ targetBranch: "main", runTests: false });

    // checkoutBranch should be called with "main" (the default)
    expect(vcs.checkoutBranch).toHaveBeenCalledWith("/tmp", "main");
  });

  it("uses detectDefaultBranch when targetBranch not given and no label", async () => {
    // Refinery uses vcsBackend.detectDefaultBranch(). Pass a mock VcsBackend
    // that returns "develop" to verify the correct branch is used.
    const run = makeRun();
    const { store, seeds } = makeMocks([]); // no branch: label
    store.getRunsByStatus = vi.fn().mockReturnValue([run]);

    const vcs = makeMockVcs({
      detectDefaultBranch: vi.fn().mockResolvedValue("develop"),
    });

    const refinery = new Refinery(store as never, seeds as never, "/tmp", vcs);
    await refinery.mergeCompleted({ runTests: false }); // no targetBranch

    expect(vcs.detectDefaultBranch).toHaveBeenCalledWith("/tmp");
    // checkoutBranch should be called with "develop" (from detectDefaultBranch)
    expect(vcs.checkoutBranch).toHaveBeenCalledWith("/tmp", "develop");
  });

  it("each run can target a different branch when multiple runs are merged", async () => {
    const run1 = makeRun({ id: "run-1", seed_id: "seed-aaa" });
    const run2 = makeRun({ id: "run-2", seed_id: "seed-bbb" });

    const { store } = makeMocks();
    store.getRunsByStatus = vi.fn().mockReturnValue([run1, run2]);

    // seed-aaa has branch:installer, seed-bbb has no label -> targets main
    const seeds = {
      getGraph: vi.fn().mockResolvedValue({ edges: [] }),
      show: vi.fn().mockImplementation(async (id: string) => ({
        status: "open",
        title: `Seed ${id}`,
        description: null,
        labels: id === "seed-aaa" ? ["branch:installer"] : [],
      })),
      update: vi.fn().mockResolvedValue(undefined),
    };

    const vcs = makeMockVcs();
    const refinery = new Refinery(store as never, seeds as never, "/tmp", vcs);
    await refinery.mergeCompleted({ targetBranch: "main", runTests: false });

    // run1 (seed-aaa) -> checkoutBranch with installer
    // run2 (seed-bbb) -> checkoutBranch with main
    const checkoutCalls = (vcs.checkoutBranch as ReturnType<typeof vi.fn>).mock.calls;
    // Filter to only the squash-merge checkout calls (not rebase-return checkouts)
    // The pattern is: checkout target -> squash merge -> commit -> ... -> checkout target (for next run)
    expect(checkoutCalls.some((c: any[]) => c[1] === "installer")).toBe(true);
    expect(checkoutCalls.some((c: any[]) => c[1] === "main")).toBe(true);
  });

  it("is non-fatal when branch label lookup fails", async () => {
    const run = makeRun();
    const { store } = makeMocks();
    store.getRunsByStatus = vi.fn().mockReturnValue([run]);

    const seeds = {
      getGraph: vi.fn().mockResolvedValue({ edges: [] }),
      show: vi.fn().mockRejectedValue(new Error("br not available")), // lookup fails
      update: vi.fn().mockResolvedValue(undefined),
    };

    const vcs = makeMockVcs();
    const refinery = new Refinery(store as never, seeds as never, "/tmp", vcs);
    // Should not throw; falls back to default target
    await expect(
      refinery.mergeCompleted({ targetBranch: "main", runTests: false }),
    ).resolves.toBeDefined();

    // Falls back to "main" (the default) — checkoutBranch called with "main"
    expect(vcs.checkoutBranch).toHaveBeenCalledWith("/tmp", "main");
  });
});
