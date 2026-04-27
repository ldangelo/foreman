/**
 * startup-sync.test.ts
 *
 * Unit tests for syncBeadStatusOnStartup() in task-backend-ops.ts.
 *
 * Tests the startup reconciliation logic that syncs br seed status from
 * SQLite run status on foreman startup.
 */

import { describe, it, expect, vi, beforeEach } from "vitest";

// ── Mock setup ──────────────────────────────────────────────────────────────
//
// Mock execFileSync so no real subprocess is spawned during tests.
// syncBeadStatusOnStartup uses execFileSync directly (not execBr) for the
// flush call to avoid the auto-appended --json flag that bypasses br's dirty flag.

const { mockExecFileSync } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn().mockReturnValue(undefined),
}));

vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return { ...actual, execFileSync: mockExecFileSync };
});

import { syncBeadStatusOnStartup } from "../task-backend-ops.js";
import type { SyncResult } from "../task-backend-ops.js";

// ── Test helpers ────────────────────────────────────────────────────────────

type MinimalRun = {
  id: string;
  seed_id: string;
  status: string;
  created_at: string;
  project_id: string;
};

function makeRun(overrides: Partial<MinimalRun> = {}): MinimalRun {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    status: "completed",
    created_at: new Date().toISOString(),
    ...overrides,
  };
}

function makeMocks() {
  const store = {
    getRunsByStatuses: vi.fn((): MinimalRun[] => []),
  };
  const taskClient = {
    show: vi.fn(async (_id: string) => ({ status: "in_progress" })),
    update: vi.fn(async () => {}),
  };
  return { store, taskClient };
}

// ── Tests ───────────────────────────────────────────────────────────────────

describe("syncBeadStatusOnStartup", () => {
  beforeEach(() => {
    mockExecFileSync.mockReset();
    mockExecFileSync.mockReturnValue(undefined);
  });

  it("returns empty result when no terminal runs exist", async () => {
    const { store, taskClient } = makeMocks();
    store.getRunsByStatuses.mockReturnValue([]);

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.synced).toBe(0);
    expect(result.mismatches).toHaveLength(0);
    expect(result.errors).toHaveLength(0);
    expect(taskClient.show).not.toHaveBeenCalled();
  });

  it("awaits an async getRunsByStatuses store implementation", async () => {
    const run = makeRun({ status: "completed" });
    const store = {
      getRunsByStatuses: vi.fn(async () => [run]),
    } satisfies Parameters<typeof syncBeadStatusOnStartup>[0];
    const taskClient = {
      show: vi.fn(async () => ({ status: "review" })),
    } satisfies Pick<Parameters<typeof syncBeadStatusOnStartup>[1], "show">;

    const result = await syncBeadStatusOnStartup(store, taskClient, "proj-1");

    expect(store.getRunsByStatuses).toHaveBeenCalledOnce();
    expect(taskClient.show).toHaveBeenCalledWith("seed-abc");
    expect(result.mismatches).toHaveLength(0);
  });

  it("queries all terminal statuses including failed and stuck", async () => {
    const { store, taskClient } = makeMocks();
    store.getRunsByStatuses.mockReturnValue([]);

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(store.getRunsByStatuses).toHaveBeenCalledOnce();
    const [statuses] = store.getRunsByStatuses.mock.calls[0] as unknown as [string[]];
    expect(statuses).toContain("completed");
    expect(statuses).toContain("merged");
    expect(statuses).toContain("pr-created");
    expect(statuses).toContain("conflict");
    expect(statuses).toContain("test-failed");
    expect(statuses).toContain("failed");
    expect(statuses).toContain("stuck");
  });

  it("passes projectId to getRunsByStatuses", async () => {
    const { store, taskClient } = makeMocks();
    store.getRunsByStatuses.mockReturnValue([]);

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-xyz");

    const [, projectId] = store.getRunsByStatuses.mock.calls[0] as unknown as [string[], string];
    expect(projectId).toBe("proj-xyz");
  });

  it("detects mismatch when completed run has seed incorrectly closed", async () => {
    // After the bead lifecycle fix: completed → review (not closed).
    // A seed that is "closed" when the run is only "completed" (not yet merged) is a mismatch.
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "closed" });

    const result: SyncResult = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0]).toMatchObject({
      seedId: "seed-abc",
      runId: "run-1",
      runStatus: "completed",
      actualSeedStatus: "closed",
      expectedSeedStatus: "review",
    });
  });

  it("detects mismatch when failed run has seed still in_progress", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "failed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(1);
    // failed (unexpected exception) → expected 'failed' in br to indicate permanent failure
    expect(result.mismatches[0].expectedSeedStatus).toBe("failed");
  });

  it("detects mismatch when stuck run has seed still in_progress", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "stuck" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0].expectedSeedStatus).toBe("open");
  });

  it("fixes mismatches by calling execFileSync update (not taskClient.update)", async () => {
    // completed run with seed incorrectly "closed" → should be updated to "review"
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "closed" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    // Uses execFileSync directly (not taskClient.update) to preserve the br dirty flag
    const updateCall = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "update" && call[1][1] === "seed-abc",
    );
    expect(updateCall).toBeDefined();
    expect(updateCall![1]).toEqual(["update", "seed-abc", "--status", "review"]);
    expect(taskClient.update).not.toHaveBeenCalled();
    expect(result.synced).toBe(1);
  });

  it("reports no mismatch when seed status already matches expected (review)", async () => {
    // After fix: completed → review. Seed at "review" = no mismatch.
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "review" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(0);
    // No execFileSync update call should be made when there's no mismatch
    const updateCalls = mockExecFileSync.mock.calls.filter(
      (call) => Array.isArray(call[1]) && call[1][0] === "update",
    );
    expect(updateCalls).toHaveLength(0);
    expect(result.synced).toBe(0);
  });

  it("detects mismatch when completed run has seed still in_progress (should be review)", async () => {
    // 'in_progress' is the old mapping — 'review' is now the expected status for completed runs
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0].expectedSeedStatus).toBe("review");
    expect(result.mismatches[0].actualSeedStatus).toBe("in_progress");
  });

  it("does not fix mismatches in dry-run mode", async () => {
    // completed run with seed incorrectly "closed" → mismatch detected but not fixed in dry-run
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "closed" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1", { dryRun: true });

    // Neither update nor flush execFileSync calls should be made in dry-run mode
    expect(mockExecFileSync).not.toHaveBeenCalled();
    expect(result.synced).toBe(0);
    expect(result.mismatches).toHaveLength(1);
  });

  it("silently skips seeds that no longer exist (not found error)", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockRejectedValue(new Error("Issue not found: seed-abc"));

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(0);
    expect(result.errors).toHaveLength(0);
    expect(result.synced).toBe(0);
  });

  it("silently skips seeds with 'not found' error variant", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockRejectedValue(new Error("seed-abc not found in database"));

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.errors).toHaveLength(0);
  });

  it("records error when taskClient.show fails with unexpected error", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockRejectedValue(new Error("Network connection timeout"));

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("seed-abc");
  });

  it("records error when execFileSync update fails, does not count as synced", async () => {
    // completed run with seed incorrectly "closed" → mismatch, update attempted but fails
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "closed" });
    // execFileSync throws when called with update args (simulates br CLI failure)
    mockExecFileSync.mockImplementation((_bin: string, args: string[]) => {
      if (Array.isArray(args) && args[0] === "update") throw new Error("Update failed");
      return undefined;
    });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(1);
    expect(result.synced).toBe(0);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("seed-abc");
  });

  it("deduplicates multiple runs for same seed, uses most recent", async () => {
    const { store, taskClient } = makeMocks();
    const olderRun = makeRun({
      id: "run-old",
      seed_id: "seed-shared",
      status: "completed",
      created_at: "2026-01-01T00:00:00.000Z",
    });
    const newerRun = makeRun({
      id: "run-new",
      seed_id: "seed-shared",
      status: "failed",
      created_at: "2026-01-02T00:00:00.000Z",
    });
    store.getRunsByStatuses.mockReturnValue([olderRun, newerRun]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    // Should only check once (deduplicated by seed_id)
    expect(taskClient.show).toHaveBeenCalledTimes(1);
    // Should use the newer run's status (failed → failed for unexpected exceptions)
    expect(result.mismatches[0].expectedSeedStatus).toBe("failed");
    expect(result.mismatches[0].runStatus).toBe("failed");
  });

  it("handles multiple seeds with different mismatch states", async () => {
    // run1: completed → expected in_progress; seed-a is "closed" → mismatch
    // run2: stuck → expected open; seed-b is "in_progress" → mismatch
    const { store, taskClient } = makeMocks();
    const run1 = makeRun({ id: "run-1", seed_id: "seed-a", status: "completed" });
    const run2 = makeRun({ id: "run-2", seed_id: "seed-b", status: "stuck" });
    store.getRunsByStatuses.mockReturnValue([run1, run2]);
    taskClient.show.mockImplementation(async (id: string) => {
      if (id === "seed-a") return { status: "closed" };      // wrong for completed (expects in_progress)
      if (id === "seed-b") return { status: "in_progress" }; // wrong for stuck (expects open)
      return { status: "open" };
    });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(2);
    expect(result.synced).toBe(2);
  });

  it("calls br sync --flush-only after fixing mismatches", async () => {
    // completed run with seed incorrectly "closed" → triggers mismatch fix and flush
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "closed" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    // execFileSync should be called with br path and ["sync", "--flush-only"]
    const flushCall = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "sync" && call[1][1] === "--flush-only",
    );
    expect(flushCall).toBeDefined();
  });

  it("passes projectPath to execFileSync sync call", async () => {
    // completed run with seed incorrectly "closed" → mismatch triggers sync call
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "closed" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1", {
      projectPath: "/my/project",
    });

    const flushCall = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "sync",
    );
    expect(flushCall).toBeDefined();
    // Third arg is the options object with cwd
    expect(flushCall![2]).toMatchObject({ cwd: "/my/project" });
  });

  it("does not call br sync --flush-only when no seeds were synced", async () => {
    // After fix: completed → review. Seed at "review" = no mismatch, no sync needed.
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    // Seed already at the correct status for a completed run (review)
    taskClient.show.mockResolvedValue({ status: "review" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    const flushCall = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "sync",
    );
    expect(flushCall).toBeUndefined();
  });

  it("does not call br sync --flush-only in dry-run mode", async () => {
    // Use "closed" (mismatch for completed) to ensure there IS a mismatch detected
    // but confirm no flush is triggered due to dry-run mode.
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "closed" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1", { dryRun: true });

    const flushCall = mockExecFileSync.mock.calls.find(
      (call) => Array.isArray(call[1]) && call[1][0] === "sync",
    );
    expect(flushCall).toBeUndefined();
  });

  it("records error when br sync --flush-only fails but still returns result", async () => {
    // completed run with seed incorrectly "closed" → mismatch triggers sync call which fails
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "closed" });
    mockExecFileSync.mockImplementation((bin: string, args: string[]) => {
      if (args[0] === "sync") throw new Error("br sync failed");
      return undefined;
    });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.synced).toBe(1);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("br sync --flush-only failed");
  });

  it("continues processing other seeds when one show() fails", async () => {
    const { store, taskClient } = makeMocks();
    const run1 = makeRun({ id: "run-1", seed_id: "seed-a", status: "completed" });
    const run2 = makeRun({ id: "run-2", seed_id: "seed-b", status: "merged" });
    store.getRunsByStatuses.mockReturnValue([run1, run2]);
    taskClient.show.mockImplementation(async (id: string) => {
      if (id === "seed-a") throw new Error("Unexpected br error");
      return { status: "in_progress" };
    });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    // seed-b should still be processed
    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0].seedId).toBe("seed-b");
    // seed-a error should be recorded
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("seed-a");
  });
});
