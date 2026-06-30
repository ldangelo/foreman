/**
 * Tests for the orphan-worktree sweep in `foreman reset`.
 *
 * Regression: the sweep must read active runs from the SAME store the rest of
 * the reset flow uses (helperStore — Postgres-backed for registered projects),
 * not the local synchronous ForemanStore. Otherwise, for registered projects,
 * worktrees belonging to live Postgres-backed ACTIVE runs are invisible to the
 * keep-set and get destroyed as "orphans".
 */

import { describe, it, expect, vi } from "vitest";
import { cleanOrphanWorktrees } from "../commands/reset.js";
import type { Run } from "../../lib/store.js";

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "bd-abc",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: "/wt/.foreman-worktrees/repo/bd-active",
    status: "running",
    started_at: new Date().toISOString(),
    completed_at: null,
    created_at: new Date().toISOString(),
    progress: null,
    ...overrides,
  };
}

describe("cleanOrphanWorktrees — keep-set from the async (helper) store", () => {
  it("does NOT remove a worktree belonging to an active run from the async store", async () => {
    const worktreesDir = "/wt/.foreman-worktrees/repo";
    const activeRun = makeRun({
      status: "running",
      worktree_path: `${worktreesDir}/bd-active`,
    });

    // Async store (mirrors PostgresStore.forProject for registered projects).
    const store = {
      getRunsByStatus: vi.fn(async (status: Run["status"], _projectId: string): Promise<Run[]> =>
        status === "running" ? [activeRun] : [],
      ),
    };

    const vcs = {
      removeWorkspace: vi.fn(async (): Promise<void> => {}),
      deleteBranch: vi.fn(async (): Promise<{ deleted: boolean }> => ({ deleted: false })),
    };

    const result = await cleanOrphanWorktrees(store, vcs, "/repo", worktreesDir, "proj-1", {
      readdir: () => ["bd-active"],
      logger: () => {},
    });

    // The active run's worktree must be preserved, not destroyed as an orphan.
    expect(vcs.removeWorkspace).not.toHaveBeenCalled();
    expect(result.worktreesRemoved).toBe(0);
    // The keep-set must have been built from the async store.
    expect(store.getRunsByStatus).toHaveBeenCalledWith("running", "proj-1");
  });

  it("removes a worktree with no active run record", async () => {
    const worktreesDir = "/wt/.foreman-worktrees/repo";
    const store = {
      getRunsByStatus: vi.fn(async (_status: Run["status"], _projectId: string): Promise<Run[]> => []),
    };
    const vcs = {
      removeWorkspace: vi.fn(async (): Promise<void> => {}),
      deleteBranch: vi.fn(async (): Promise<{ deleted: boolean }> => ({ deleted: true })),
    };

    const result = await cleanOrphanWorktrees(store, vcs, "/repo", worktreesDir, "proj-1", {
      readdir: () => ["bd-orphan"],
      logger: () => {},
    });

    expect(vcs.removeWorkspace).toHaveBeenCalledWith("/repo", `${worktreesDir}/bd-orphan`);
    expect(result.worktreesRemoved).toBe(1);
    expect(result.branchesDeleted).toBe(1);
  });

  it("treats pending and running as the active keep-set (failed/stuck are sweepable)", async () => {
    const worktreesDir = "/wt/.foreman-worktrees/repo";
    const pendingRun = makeRun({
      status: "pending",
      worktree_path: `${worktreesDir}/bd-pending`,
    });
    const failedRun = makeRun({
      status: "failed",
      worktree_path: `${worktreesDir}/bd-failed`,
    });
    const store = {
      getRunsByStatus: vi.fn(async (status: Run["status"], _projectId: string): Promise<Run[]> => {
        if (status === "pending") return [pendingRun];
        if (status === "running") return [];
        return [failedRun];
      }),
    };
    const vcs = {
      removeWorkspace: vi.fn(async (): Promise<void> => {}),
      deleteBranch: vi.fn(async (): Promise<{ deleted: boolean }> => ({ deleted: false })),
    };

    const result = await cleanOrphanWorktrees(store, vcs, "/repo", worktreesDir, "proj-1", {
      readdir: () => ["bd-pending", "bd-failed"],
      logger: () => {},
    });

    // bd-pending is kept (active); bd-failed is swept.
    expect(vcs.removeWorkspace).toHaveBeenCalledTimes(1);
    expect(vcs.removeWorkspace).toHaveBeenCalledWith("/repo", `${worktreesDir}/bd-failed`);
    expect(result.worktreesRemoved).toBe(1);
    // "failed"/"stuck" must NOT be consulted as active statuses.
    expect(store.getRunsByStatus).not.toHaveBeenCalledWith("failed", "proj-1");
  });

  it("ignores already-missing worktrees and branches without logging errors", async () => {
    const worktreesDir = "/wt/.foreman-worktrees/repo";
    const logs: string[] = [];
    const store = {
      getRunsByStatus: vi.fn(async (_status: Run["status"], _projectId: string): Promise<Run[]> => []),
    };
    const vcs = {
      removeWorkspace: vi.fn(async (): Promise<void> => {
        throw new Error("path is not a working tree");
      }),
      deleteBranch: vi.fn(async (): Promise<{ deleted: boolean }> => {
        throw new Error("branch missing");
      }),
    };

    const result = await cleanOrphanWorktrees(store, vcs, "/repo", worktreesDir, "proj-1", {
      readdir: () => ["bd-gone"],
      logger: (msg) => logs.push(msg),
    });

    expect(vcs.removeWorkspace).toHaveBeenCalledWith("/repo", `${worktreesDir}/bd-gone`);
    expect(vcs.deleteBranch).toHaveBeenCalledWith("/repo", "foreman/bd-gone", { force: true });
    expect(result.worktreesRemoved).toBe(0);
    expect(result.branchesDeleted).toBe(0);
    expect(logs.some((line) => line.includes("error removing orphaned worktree"))).toBe(false);
  });

  it("logs unexpected orphan worktree removal errors", async () => {
    const worktreesDir = "/wt/.foreman-worktrees/repo";
    const logs: string[] = [];
    const store = {
      getRunsByStatus: vi.fn(async (_status: Run["status"], _projectId: string): Promise<Run[]> => []),
    };
    const vcs = {
      removeWorkspace: vi.fn(async (): Promise<void> => {
        throw new Error("permission denied");
      }),
      deleteBranch: vi.fn(async (): Promise<{ deleted: boolean }> => ({ deleted: false })),
    };

    const result = await cleanOrphanWorktrees(store, vcs, "/repo", worktreesDir, "proj-1", {
      readdir: () => ["bd-error"],
      logger: (msg) => logs.push(msg),
    });

    expect(result.worktreesRemoved).toBe(0);
    expect(result.branchesDeleted).toBe(0);
    expect(logs.some((line) => line.includes("error removing orphaned worktree: permission denied"))).toBe(true);
  });
});
