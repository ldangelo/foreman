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
// vi.hoisted() ensures the mock variable is ready before the module factory runs.
//
// NOTE: We mock execFileSync (not execBr) because task-backend-ops.ts uses
// execFileSync directly for br sync --flush-only to avoid the --json flag
// that execBr auto-appends (which would cause the sync to silently no-op).

const { mockExecFileSync } = vi.hoisted(() => ({
  mockExecFileSync: vi.fn().mockReturnValue(undefined),
}));

vi.mock("node:child_process", () => ({
  execFileSync: mockExecFileSync,
}));

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
    show: vi.fn(async () => ({ status: "in_progress" })),
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

  it("queries all terminal statuses including failed and stuck", async () => {
    const { store, taskClient } = makeMocks();
    store.getRunsByStatuses.mockReturnValue([]);

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(store.getRunsByStatuses).toHaveBeenCalledOnce();
    const [statuses] = store.getRunsByStatuses.mock.calls[0] as [string[]];
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

    const [, projectId] = store.getRunsByStatuses.mock.calls[0] as [string[], string];
    expect(projectId).toBe("proj-xyz");
  });

  it("detects mismatch when completed run has seed still in_progress", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result: SyncResult = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0]).toMatchObject({
      seedId: "seed-abc",
      runId: "run-1",
      runStatus: "completed",
      actualSeedStatus: "in_progress",
      expectedSeedStatus: "closed",
    });
  });

  it("detects mismatch when failed run has seed still in_progress", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "failed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0].expectedSeedStatus).toBe("open");
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

  it("fixes mismatches by calling taskClient.update", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(taskClient.update).toHaveBeenCalledWith("seed-abc", { status: "closed" });
    expect(result.synced).toBe(1);
  });

  it("reports no mismatch when seed status already matches expected", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "closed" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(0);
    expect(taskClient.update).not.toHaveBeenCalled();
    expect(result.synced).toBe(0);
  });

  it("does not fix mismatches in dry-run mode", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1", { dryRun: true });

    expect(taskClient.update).not.toHaveBeenCalled();
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

  it("records error when taskClient.update fails, does not count as synced", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });
    taskClient.update.mockRejectedValue(new Error("Update failed"));

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
    // Should use the newer run's status (failed → open)
    expect(result.mismatches[0].expectedSeedStatus).toBe("open");
    expect(result.mismatches[0].runStatus).toBe("failed");
  });

  it("handles multiple seeds with different mismatch states", async () => {
    const { store, taskClient } = makeMocks();
    const run1 = makeRun({ id: "run-1", seed_id: "seed-a", status: "completed" });
    const run2 = makeRun({ id: "run-2", seed_id: "seed-b", status: "stuck" });
    store.getRunsByStatuses.mockReturnValue([run1, run2]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    const result = await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(result.mismatches).toHaveLength(2);
    expect(result.synced).toBe(2);
  });

  it("calls br sync --flush-only after fixing mismatches", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    // execFileSync is called with the br binary path and ["sync", "--flush-only"]
    // (no --json flag — that's the whole point of this fix)
    expect(mockExecFileSync).toHaveBeenCalledWith(
      expect.stringContaining("br"),
      ["sync", "--flush-only"],
      expect.any(Object),
    );
  });

  it("passes projectPath as cwd to execFileSync sync call", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1", {
      projectPath: "/my/project",
    });

    expect(mockExecFileSync).toHaveBeenCalledWith(
      expect.stringContaining("br"),
      ["sync", "--flush-only"],
      expect.objectContaining({ cwd: "/my/project" }),
    );
  });

  it("does not call br sync --flush-only when no seeds were synced", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    // Seed already at the correct status
    taskClient.show.mockResolvedValue({ status: "closed" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1");

    expect(mockExecFileSync).not.toHaveBeenCalled();
  });

  it("does not call br sync --flush-only in dry-run mode", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });

    await syncBeadStatusOnStartup(store as any, taskClient as any, "proj-1", { dryRun: true });

    expect(mockExecFileSync).not.toHaveBeenCalled();
  });

  it("records error when br sync --flush-only fails but still returns result", async () => {
    const { store, taskClient } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatuses.mockReturnValue([run]);
    taskClient.show.mockResolvedValue({ status: "in_progress" });
    mockExecFileSync.mockImplementation(() => { throw new Error("br sync failed"); });

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
