/**
 * Tests for reset.ts with BeadsRustClient (br) backend.
 *
 * Covers TRD-008: Update reset.ts to use BeadsRustClient when
 * FOREMAN_TASK_BACKEND=br.
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  detectAndFixMismatches,
  resetSeedToOpen,
  detectAndHandleStaleBranches,
  countCommitsAhead,
  isBranchMergedIntoTarget,
} from "../commands/reset.js";
import type { IShowUpdateClient, ExecFileAsyncFn } from "../commands/reset.js";
import type { ForemanStore, Run } from "../../lib/store.js";
import type { BrIssueDetail } from "../../lib/beads-rust.js";
import type { UpdateOptions } from "../../lib/task-client.js";
import type { MergeQueueEntry, MergeQueueStatus } from "../../orchestrator/merge-queue.js";

// ── Helpers ─────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "bd-abc",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: new Date().toISOString(),
    created_at: new Date().toISOString(),
    progress: null,    ...overrides,
  };
}

function makeBrDetail(status: string): BrIssueDetail {
  return {
    id: "bd-abc",
    title: "Some task",
    type: "task",
    priority: "2",
    status,
    assignee: null,
    parent: null,
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
    description: null,
    labels: [],
    estimate_minutes: null,
    dependencies: [],
    dependents: [],
  };
}

// Type alias for the store pick used by detectAndFixMismatches.
type StoreMock = Pick<ForemanStore, "getRunsByStatus" | "getActiveRuns">;

function makeBrMocks() {
  const storeFn = vi.fn((_status: string, _projectId?: string): Run[] => []);
  const activeRunsFn = vi.fn((_projectId?: string): Run[] => []);
  // Cast the mock store to satisfy StoreMock for the function under test.
  // The vi.fn signature is compatible at runtime; the cast is needed because
  // vi.fn wraps the function in a Mock type.
  const store = {
    getRunsByStatus: storeFn,
    getActiveRuns: activeRunsFn,
  } as unknown as StoreMock & {
    getRunsByStatus: typeof storeFn;
    getActiveRuns: typeof activeRunsFn;
  };
  const brClient = {
    show: vi.fn(async (_id: string): Promise<BrIssueDetail> => makeBrDetail("in_progress")),
    update: vi.fn(async (_id: string, _opts: UpdateOptions): Promise<void> => {}),
  };
  return { store, brClient };
}

// ── detectAndFixMismatches with BeadsRustClient ──────────────────────────

describe("detectAndFixMismatches — br backend (BeadsRustClient)", () => {
  it("detects mismatch when completed run has br issue in open state (should be review awaiting merge)", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockResolvedValue(makeBrDetail("open"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0]).toMatchObject({
      seedId: "bd-abc",
      runId: "run-1",
      runStatus: "completed",
      actualSeedStatus: "open",
      expectedSeedStatus: "review",
    });
  });

  it("calls brClient.update to fix a mismatch (completed run should have review bead — pipeline done, awaiting merge)", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockResolvedValue(makeBrDetail("open"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(brClient.update).toHaveBeenCalledWith("bd-abc", { status: "review" });
    expect(result.fixed).toBe(1);
  });

  it("does not call brClient.update in dry-run mode", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockResolvedValue(makeBrDetail("open"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
      { dryRun: true },
    );

    expect(brClient.update).not.toHaveBeenCalled();
    expect(result.fixed).toBe(0);
    expect(result.mismatches).toHaveLength(1);
  });

  it("reports no mismatch when br issue status already matches expected (review for completed run)", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    // completed → review: bead already in 'review' means no mismatch
    brClient.show.mockResolvedValue(makeBrDetail("review"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.mismatches).toHaveLength(0);
    expect(brClient.update).not.toHaveBeenCalled();
  });

  it("silently skips br issues that are not found", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-missing", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockRejectedValue(new Error("Issue not found: bd-missing"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.mismatches).toHaveLength(0);
    expect(result.errors).toHaveLength(0);
  });

  it("records error when brClient.show fails with unexpected error", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    brClient.show.mockRejectedValue(new Error("Database connection lost"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("bd-abc");
  });

  it("records error when brClient.update fails, does not count as fixed", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    // Use "open" so there IS a mismatch (completed → review, but bead is open)
    brClient.show.mockResolvedValue(makeBrDetail("open"));
    brClient.update.mockRejectedValue(new Error("br update failed: permission denied"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.mismatches).toHaveLength(1);
    expect(result.fixed).toBe(0);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("bd-abc");
  });

  it("skips br issues already in the resetSeedIds set", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-already-reset", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(["bd-already-reset"]),
    );

    expect(brClient.show).not.toHaveBeenCalled();
    expect(result.mismatches).toHaveLength(0);
  });

  it("handles merged run with br issue in_progress", async () => {
    const { store, brClient } = makeBrMocks();
    const run = makeRun({ seed_id: "bd-abc", status: "merged" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "merged" ? [run] : [],
    );
    brClient.show.mockResolvedValue(makeBrDetail("in_progress"));

    const result = await detectAndFixMismatches(
      store,
      brClient,
      "proj-1",
      new Set(),
    );

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0].expectedSeedStatus).toBe("closed");
    expect(brClient.update).toHaveBeenCalledWith("bd-abc", { status: "closed" });
  });
});

// ── resetSeedToOpen — closed-seed guard ──────────────────────────────────

describe("resetSeedToOpen", () => {
  function makeSeedsClient(status: string) {
    return {
      show: vi.fn(async (_id: string) => ({ status })),
      update: vi.fn(async (_id: string, _opts: UpdateOptions): Promise<void> => {}),
    };
  }

  it("does not reopen a seed that is already closed unless forced", async () => {
    const seeds = makeSeedsClient("closed");

    const result = await resetSeedToOpen("bd-completed", seeds);

    expect(result.action).toBe("skipped-closed");
    expect(result.previousStatus).toBe("closed");
    expect(seeds.update).not.toHaveBeenCalled();
  });

  it("reopens a closed seed when force is explicitly set", async () => {
    const seeds = makeSeedsClient("closed");

    const result = await resetSeedToOpen("bd-completed", seeds, { force: true });

    expect(result.action).toBe("reset");
    expect(result.previousStatus).toBe("closed");
    expect(seeds.update).toHaveBeenCalledWith("bd-completed", { status: "open" });
  });

  it("resets a seed that is in_progress to open", async () => {
    const seeds = makeSeedsClient("in_progress");

    const result = await resetSeedToOpen("bd-active", seeds);

    expect(result.action).toBe("reset");
    expect(result.previousStatus).toBe("in_progress");
    expect(seeds.update).toHaveBeenCalledWith("bd-active", { status: "open" });
  });

  it("returns already-open without calling update when seed is already open", async () => {
    const seeds = makeSeedsClient("open");

    const result = await resetSeedToOpen("bd-open", seeds);

    expect(result.action).toBe("already-open");
    expect(result.previousStatus).toBe("open");
    expect(seeds.update).not.toHaveBeenCalled();
  });

  it("returns not-found when seed does not exist (not found error)", async () => {
    const seeds = {
      show: vi.fn(async (_id: string) => { throw new Error("Issue not found: bd-gone"); }),
      update: vi.fn(async (_id: string, _opts: UpdateOptions): Promise<void> => {}),
    };

    const result = await resetSeedToOpen("bd-gone", seeds);

    expect(result.action).toBe("not-found");
    expect(seeds.update).not.toHaveBeenCalled();
  });

  it("returns error when show fails with unexpected error", async () => {
    const seeds = {
      show: vi.fn(async (_id: string) => { throw new Error("Database connection lost"); }),
      update: vi.fn(async (_id: string, _opts: UpdateOptions): Promise<void> => {}),
    };

    const result = await resetSeedToOpen("bd-abc", seeds);

    expect(result.action).toBe("error");
    expect(result.error).toContain("Database connection lost");
    expect(seeds.update).not.toHaveBeenCalled();
  });

  it("returns error when update fails", async () => {
    const seeds = {
      show: vi.fn(async (_id: string) => ({ status: "in_progress" })),
      update: vi.fn(async (_id: string, _opts: UpdateOptions): Promise<void> => {
        throw new Error("br update failed: permission denied");
      }),
    };

    const result = await resetSeedToOpen("bd-abc", seeds);

    expect(result.action).toBe("error");
    expect(result.error).toContain("permission denied");
  });

  // ── dry-run mode ─────────────────────────────────────────────────────

  it("dry-run: returns 'reset' action but does NOT call update for in_progress seed", async () => {
    const seeds = makeSeedsClient("in_progress");

    const result = await resetSeedToOpen("bd-active", seeds, { dryRun: true });

    expect(result.action).toBe("reset");
    expect(result.previousStatus).toBe("in_progress");
    // update must NOT be called in dry-run mode
    expect(seeds.update).not.toHaveBeenCalled();
  });

  it("dry-run: returns 'skipped-closed' for a closed seed unless force is set", async () => {
    const seeds = makeSeedsClient("closed");

    const result = await resetSeedToOpen("bd-completed", seeds, { dryRun: true });

    expect(result.action).toBe("skipped-closed");
    expect(result.previousStatus).toBe("closed");
    expect(seeds.update).not.toHaveBeenCalled();
  });

  it("dry-run: returns 'reset' for a closed seed when force is set", async () => {
    const seeds = makeSeedsClient("closed");

    const result = await resetSeedToOpen("bd-completed", seeds, { dryRun: true, force: true });

    expect(result.action).toBe("reset");
    expect(result.previousStatus).toBe("closed");
    expect(seeds.update).not.toHaveBeenCalled();
  });

  it("dry-run: returns 'already-open' for an open seed (consistent with non-dry-run)", async () => {
    const seeds = makeSeedsClient("open");

    const result = await resetSeedToOpen("bd-open", seeds, { dryRun: true });

    expect(result.action).toBe("already-open");
    expect(result.previousStatus).toBe("open");
    expect(seeds.update).not.toHaveBeenCalled();
  });
});

// ── resetCommand uses br backend when FOREMAN_TASK_BACKEND=br ────────────

describe("reset command — backend selection via getTaskBackend()", () => {
  let originalEnv: string | undefined;

  beforeEach(() => {
    originalEnv = process.env.FOREMAN_TASK_BACKEND;
  });

  afterEach(() => {
    if (originalEnv === undefined) {
      delete process.env.FOREMAN_TASK_BACKEND;
    } else {
      process.env.FOREMAN_TASK_BACKEND = originalEnv;
    }
  });

  it("getTaskBackend() returns 'br' when FOREMAN_TASK_BACKEND=br", async () => {
    process.env.FOREMAN_TASK_BACKEND = "br";
    const { getTaskBackend } = await import("../../lib/feature-flags.js");
    expect(getTaskBackend()).toBe("br");
  });

  // TRD-023: default changed from 'sd' to 'br'
  it("getTaskBackend() returns 'br' when FOREMAN_TASK_BACKEND is unset", async () => {
    delete process.env.FOREMAN_TASK_BACKEND;
    const { getTaskBackend } = await import("../../lib/feature-flags.js");
    expect(getTaskBackend()).toBe("br");
  });

});

// ── countCommitsAhead ────────────────────────────────────────────────────────

describe("countCommitsAhead", () => {
  it("returns count from git rev-list --count output", async () => {
    const execFn: ExecFileAsyncFn = vi.fn(async () => ({ stdout: "3\n", stderr: "" }));
    const count = await countCommitsAhead("/repo", "dev", "foreman/bd-abc", execFn);
    expect(count).toBe(3);
    expect(execFn).toHaveBeenCalledWith(
      "git",
      ["rev-list", "--count", "dev..foreman/bd-abc"],
      { cwd: "/repo" },
    );
  });

  it("returns 0 when git command fails (branch doesn't exist)", async () => {
    const execFn: ExecFileAsyncFn = vi.fn(async () => { throw new Error("fatal: bad revision"); });
    const count = await countCommitsAhead("/repo", "dev", "foreman/bd-missing", execFn);
    expect(count).toBe(0);
  });

  it("returns 0 for empty stdout", async () => {
    const execFn: ExecFileAsyncFn = vi.fn(async () => ({ stdout: "", stderr: "" }));
    const count = await countCommitsAhead("/repo", "dev", "foreman/bd-abc", execFn);
    expect(count).toBe(0);
  });

  it("returns 0 for malformed stdout", async () => {
    const execFn: ExecFileAsyncFn = vi.fn(async () => ({ stdout: "NaN\n", stderr: "" }));
    const count = await countCommitsAhead("/repo", "dev", "foreman/bd-abc", execFn);
    expect(count).toBe(0);
  });
});

// ── isBranchMergedIntoTarget ─────────────────────────────────────────────────

describe("isBranchMergedIntoTarget", () => {
  it("returns true when merge-base exits with code 0 (branch is ancestor)", async () => {
    const execFn: ExecFileAsyncFn = vi.fn(async () => ({ stdout: "", stderr: "" }));
    const result = await isBranchMergedIntoTarget("/repo", "dev", "foreman/bd-abc", execFn);
    expect(result).toBe(true);
    expect(execFn).toHaveBeenCalledWith(
      "git",
      ["merge-base", "--is-ancestor", "foreman/bd-abc", "dev"],
      { cwd: "/repo" },
    );
  });

  it("returns false when merge-base exits non-zero (branch is NOT an ancestor)", async () => {
    const execFn: ExecFileAsyncFn = vi.fn(async () => {
      throw new Error("exit code 1");
    });
    const result = await isBranchMergedIntoTarget("/repo", "dev", "foreman/bd-abc", execFn);
    expect(result).toBe(false);
  });

  it("returns false when branch doesn't exist", async () => {
    const execFn: ExecFileAsyncFn = vi.fn(async () => {
      throw new Error("fatal: no such ref");
    });
    const result = await isBranchMergedIntoTarget("/repo", "dev", "foreman/bd-missing", execFn);
    expect(result).toBe(false);
  });
});

// ── detectAndHandleStaleBranches ─────────────────────────────────────────────

function makeMergeQueueEntry(
  overrides: Partial<MergeQueueEntry> = {},
): MergeQueueEntry {
  return {
    id: 1,
    branch_name: "foreman/bd-abc",
    seed_id: "bd-abc",
    run_id: "run-1",
    agent_name: null,
    files_modified: [],
    enqueued_at: new Date().toISOString(),
    started_at: null,
    completed_at: null,
    status: "pending" as MergeQueueStatus,
    resolved_tier: null,
    error: null,
    retry_count: 0,
    last_attempted_at: null,
    ...overrides,
  };
}

type StoreMockForStale = Pick<ForemanStore, "getRunsByStatus" | "getActiveRuns" | "updateRun">;

function makeStaleBranchMocks() {
  const getRunsByStatusFn = vi.fn((_status: string, _projectId?: string): Run[] => []);
  const getActiveRunsFn = vi.fn((_projectId?: string): Run[] => []);
  const updateRunFn = vi.fn((_id: string, _upd: Partial<Run>): void => {});

  const store = {
    getRunsByStatus: getRunsByStatusFn,
    getActiveRuns: getActiveRunsFn,
    updateRun: updateRunFn,
  } as unknown as StoreMockForStale & {
    getRunsByStatus: typeof getRunsByStatusFn;
    getActiveRuns: typeof getActiveRunsFn;
    updateRun: typeof updateRunFn;
  };

  const brClient: IShowUpdateClient = {
    show: vi.fn(async (_id: string) => ({ status: "review" })),
    update: vi.fn(async (_id: string, _opts: UpdateOptions): Promise<void> => {}),
  };

  const listFn = vi.fn((_status?: MergeQueueStatus): MergeQueueEntry[] => []);
  const removeFn = vi.fn((_id: number): void => {});

  const mergeQueue = {
    list: listFn,
    remove: removeFn,
  } as unknown as {
    list: typeof listFn;
    remove: typeof removeFn;
  };

  return { store, brClient, mergeQueue };
}

// Helpers for execFn
const execFnMerged: ExecFileAsyncFn = vi.fn(async (_cmd, args) => {
  // merge-base --is-ancestor succeeds (branch IS merged)
  if (args.includes("--is-ancestor")) return { stdout: "", stderr: "" };
  // rev-list --count: 0 commits ahead
  if (args.includes("--count")) return { stdout: "0\n", stderr: "" };
  return { stdout: "", stderr: "" };
});

const execFnNotMerged: ExecFileAsyncFn = vi.fn(async (_cmd, args) => {
  // merge-base --is-ancestor fails (branch is NOT merged)
  if (args.includes("--is-ancestor")) throw new Error("exit code 1");
  // rev-list --count: 2 commits ahead
  if (args.includes("--count")) return { stdout: "2\n", stderr: "" };
  return { stdout: "", stderr: "" };
});

describe("detectAndHandleStaleBranches", () => {
  it("returns empty results when there are no completed runs", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    store.getRunsByStatus.mockReturnValue([]);

    const result = await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(),
      { dryRun: true, execFileAsync: execFnMerged },
    );

    expect(result.results).toHaveLength(0);
    expect(result.closed).toBe(0);
    expect(result.reset).toBe(0);
  });

  it("skips seeds in skipSeedIds", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    const run = makeRun({ seed_id: "bd-skip", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );

    const result = await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(["bd-skip"]),
      { dryRun: true, execFileAsync: execFnMerged },
    );

    expect(result.results).toHaveLength(0);
    expect(result.closed).toBe(0);
  });

  it("skips seeds with active (pending/merging) MQ entries", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    const run = makeRun({ seed_id: "bd-active", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    mergeQueue.list.mockReturnValue([
      makeMergeQueueEntry({ seed_id: "bd-active", status: "pending" }),
    ]);

    const result = await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(),
      { dryRun: true, execFileAsync: execFnMerged },
    );

    const skipResult = result.results.find((r) => r.seedId === "bd-active");
    expect(skipResult?.action).toBe("skip");
    expect(result.closed).toBe(0);
    expect(result.reset).toBe(0);
  });

  it("skips seeds with merging MQ entries", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    const run = makeRun({ seed_id: "bd-merging", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    mergeQueue.list.mockReturnValue([
      makeMergeQueueEntry({ seed_id: "bd-merging", status: "merging" }),
    ]);

    const result = await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(),
      { dryRun: true, execFileAsync: execFnNotMerged },
    );

    const skipResult = result.results.find((r) => r.seedId === "bd-merging");
    expect(skipResult?.action).toBe("skip");
  });

  it("closes bead when branch is already merged into target", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    const run = makeRun({ seed_id: "bd-merged", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    mergeQueue.list.mockReturnValue([]);

    const result = await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(),
      { dryRun: false, execFileAsync: execFnMerged },
    );

    expect(result.closed).toBe(1);
    expect(result.reset).toBe(0);
    const closeResult = result.results.find((r) => r.seedId === "bd-merged");
    expect(closeResult?.action).toBe("close");
    expect(brClient.update).toHaveBeenCalledWith("bd-merged", { status: "closed" });
    expect(store.updateRun).toHaveBeenCalledWith(run.id, expect.objectContaining({ status: "merged" }));
  });

  it("resets bead to open when branch is NOT merged into target", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    const run = makeRun({ seed_id: "bd-unmerged", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    mergeQueue.list.mockReturnValue([]);

    const result = await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(),
      { dryRun: false, execFileAsync: execFnNotMerged },
    );

    expect(result.reset).toBe(1);
    expect(result.closed).toBe(0);
    const resetResult = result.results.find((r) => r.seedId === "bd-unmerged");
    expect(resetResult?.action).toBe("reset");
    expect(brClient.update).toHaveBeenCalledWith("bd-unmerged", { status: "open" });
    expect(store.updateRun).toHaveBeenCalled();
  });

  it("dry-run: counts close/reset but does not call update", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    const runMerged = makeRun({ id: "run-m", seed_id: "bd-merged2", status: "completed" });
    const runUnmerged = makeRun({ id: "run-u", seed_id: "bd-unmerged2", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [runMerged, runUnmerged] : [],
    );
    mergeQueue.list.mockReturnValue([]);

    // execFn: merged for bd-merged2, not-merged for bd-unmerged2
    const execFnMixed: ExecFileAsyncFn = vi.fn(async (_cmd, args, opts) => {
      const cwd = opts?.cwd ?? "";
      if (args.includes("--is-ancestor")) {
        // Return success only for bd-merged2 branch
        if (cwd === "/repo") {
          // We need to distinguish by args content — both calls use same args format.
          // Use a stateful counter: first call = merged, second = not merged
          const callCount = (execFnMixed as ReturnType<typeof vi.fn>).mock.calls.length;
          if (callCount % 2 === 1) return { stdout: "", stderr: "" }; // merged
          throw new Error("exit code 1");
        }
      }
      return { stdout: "", stderr: "" };
    });

    const result = await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(),
      { dryRun: true, execFileAsync: execFnMixed },
    );

    // In dry-run, updates should not be called
    expect(brClient.update).not.toHaveBeenCalled();
    expect(store.updateRun).not.toHaveBeenCalled();
    // But counts should reflect what would happen
    expect(result.closed + result.reset).toBe(2);
  });

  it("removes MQ entries for the seed when closing or resetting", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    const run = makeRun({ seed_id: "bd-with-mq", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    // A failed MQ entry for this seed (not pending/merging, so it won't be skipped)
    const mqEntry = makeMergeQueueEntry({ id: 42, seed_id: "bd-with-mq", status: "failed" });
    mergeQueue.list.mockReturnValue([mqEntry]);

    await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(),
      { dryRun: false, execFileAsync: execFnMerged },
    );

    expect(mergeQueue.remove).toHaveBeenCalledWith(42);
  });

  it("skips seeds with active dispatched runs (pending/running)", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    const run = makeRun({ seed_id: "bd-active-run", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    // There's an active (pending) run for this seed
    store.getActiveRuns.mockReturnValue([
      makeRun({ seed_id: "bd-active-run", status: "pending" }),
    ]);
    mergeQueue.list.mockReturnValue([]);

    const result = await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(),
      { dryRun: true, execFileAsync: execFnMerged },
    );

    // Should be skipped because there's an active run
    expect(result.results).toHaveLength(0);
    expect(result.closed).toBe(0);
  });

  it("treats git errors as not-merged (safe default: reset bead to open)", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    const run = makeRun({ seed_id: "bd-git-err", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    mergeQueue.list.mockReturnValue([]);

    // isBranchMergedIntoTarget swallows errors and returns false (safe default).
    // detectAndHandleStaleBranches therefore treats this as "not merged" and
    // produces action = "reset" (bead to open) rather than "error".
    const execFnError: ExecFileAsyncFn = async () => {
      throw new Error("Unexpected git error");
    };

    const result = await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(),
      { dryRun: false, execFileAsync: execFnError },
    );

    // Git errors fall through as "not merged" → safe reset to open
    const resetResult = result.results.find((r) => r.seedId === "bd-git-err");
    expect(resetResult?.action).toBe("reset");
    expect(result.reset).toBe(1);
    expect(result.errors).toHaveLength(0);
  });

  it("handles bead not found gracefully when closing", async () => {
    const { store, brClient, mergeQueue } = makeStaleBranchMocks();
    const run = makeRun({ seed_id: "bd-gone", status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: unknown[]) =>
      args[0] === "completed" ? [run] : [],
    );
    mergeQueue.list.mockReturnValue([]);
    (brClient.update as ReturnType<typeof vi.fn>).mockRejectedValue(
      new Error("Issue not found: bd-gone"),
    );

    const result = await detectAndHandleStaleBranches(
      store, brClient as IShowUpdateClient, mergeQueue as unknown as import("../../orchestrator/merge-queue.js").MergeQueue,
      "/repo", "proj-1", new Set(),
      { dryRun: false, execFileAsync: execFnMerged },
    );

    // Error is silently ignored for "not found"
    expect(result.errors).toHaveLength(0);
    // Run should still be marked as merged because the branch has already landed
    expect(store.updateRun).toHaveBeenCalledWith(run.id, expect.objectContaining({ status: "merged" }));
  });
});
