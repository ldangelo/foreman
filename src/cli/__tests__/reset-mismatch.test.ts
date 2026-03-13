import { describe, it, expect, vi, beforeEach } from "vitest";
import {
  mapRunStatusToSeedStatus,
  detectAndFixMismatches,
} from "../commands/reset.js";
import type { Run } from "../../lib/store.js";

// ── Helpers ─────────────────────────────────────────────────────────────

function makeRun(overrides: Partial<Run> = {}): Run {
  return {
    id: "run-1",
    project_id: "proj-1",
    seed_id: "seed-abc",
    agent_type: "claude-sonnet-4-6",
    session_key: null,
    worktree_path: "/tmp/wt",
    status: "completed",
    started_at: new Date().toISOString(),
    completed_at: new Date().toISOString(),
    created_at: new Date().toISOString(),
    progress: null,
    tmux_session: null,
    ...overrides,
  };
}

function makeMocks() {
  const store = {
    getRunsByStatus: vi.fn((): Run[] => []),
  };
  const seeds = {
    show: vi.fn(async () => ({ status: "in_progress" })),
    update: vi.fn(async () => {}),
  };
  return { store, seeds };
}

// ── mapRunStatusToSeedStatus tests ───────────────────────────────────────

describe("mapRunStatusToSeedStatus", () => {
  it("maps pending to in_progress", () => {
    expect(mapRunStatusToSeedStatus("pending")).toBe("in_progress");
  });

  it("maps running to in_progress", () => {
    expect(mapRunStatusToSeedStatus("running")).toBe("in_progress");
  });

  it("maps completed to closed", () => {
    expect(mapRunStatusToSeedStatus("completed")).toBe("closed");
  });

  it("maps failed to open", () => {
    expect(mapRunStatusToSeedStatus("failed")).toBe("open");
  });

  it("maps stuck to open", () => {
    expect(mapRunStatusToSeedStatus("stuck")).toBe("open");
  });

  it("maps merged to closed", () => {
    expect(mapRunStatusToSeedStatus("merged")).toBe("closed");
  });

  it("maps pr-created to closed", () => {
    expect(mapRunStatusToSeedStatus("pr-created")).toBe("closed");
  });

  it("maps conflict to open", () => {
    expect(mapRunStatusToSeedStatus("conflict")).toBe("open");
  });

  it("maps test-failed to open", () => {
    expect(mapRunStatusToSeedStatus("test-failed")).toBe("open");
  });

  it("maps unknown status to open", () => {
    expect(mapRunStatusToSeedStatus("unknown-status")).toBe("open");
  });
});

// ── detectAndFixMismatches tests ─────────────────────────────────────────

describe("detectAndFixMismatches", () => {
  it("returns empty result when no terminal runs exist", async () => {
    const { store, seeds } = makeMocks();
    store.getRunsByStatus.mockReturnValue([]);

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set());

    expect(result.mismatches).toHaveLength(0);
    expect(result.fixed).toBe(0);
    expect(result.errors).toHaveLength(0);
    expect(seeds.show).not.toHaveBeenCalled();
  });

  it("detects mismatch when completed run has seed still in_progress", async () => {
    const { store, seeds } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: any[]) =>
      args[0] === "completed" ? [run] : []
    );
    seeds.show.mockResolvedValue({ status: "in_progress" });

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set());

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0]).toMatchObject({
      seedId: "seed-abc",
      runId: "run-1",
      runStatus: "completed",
      actualSeedStatus: "in_progress",
      expectedSeedStatus: "closed",
    });
  });

  it("detects mismatch when merged run has seed still in_progress", async () => {
    const { store, seeds } = makeMocks();
    const run = makeRun({ status: "merged" });
    store.getRunsByStatus.mockImplementation((...args: any[]) =>
      args[0] === "merged" ? [run] : []
    );
    seeds.show.mockResolvedValue({ status: "in_progress" });

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set());

    expect(result.mismatches).toHaveLength(1);
    expect(result.mismatches[0].expectedSeedStatus).toBe("closed");
  });

  it("fixes mismatches by calling seeds.update", async () => {
    const { store, seeds } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: any[]) =>
      args[0] === "completed" ? [run] : []
    );
    seeds.show.mockResolvedValue({ status: "in_progress" });

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set());

    expect(seeds.update).toHaveBeenCalledWith("seed-abc", { status: "closed" });
    expect(result.fixed).toBe(1);
  });

  it("does not call seeds.update in dry-run mode", async () => {
    const { store, seeds } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: any[]) =>
      args[0] === "completed" ? [run] : []
    );
    seeds.show.mockResolvedValue({ status: "in_progress" });

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set(), { dryRun: true });

    expect(seeds.update).not.toHaveBeenCalled();
    expect(result.fixed).toBe(0);
    expect(result.mismatches).toHaveLength(1);
  });

  it("skips seeds that are in the resetSeedIds set", async () => {
    const { store, seeds } = makeMocks();
    const run = makeRun({ status: "completed", seed_id: "seed-already-reset" });
    store.getRunsByStatus.mockImplementation((...args: any[]) =>
      args[0] === "completed" ? [run] : []
    );

    const resetSeedIds = new Set(["seed-already-reset"]);
    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", resetSeedIds);

    expect(seeds.show).not.toHaveBeenCalled();
    expect(result.mismatches).toHaveLength(0);
  });

  it("reports no mismatch when seed status already matches expected", async () => {
    const { store, seeds } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: any[]) =>
      args[0] === "completed" ? [run] : []
    );
    seeds.show.mockResolvedValue({ status: "closed" });

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set());

    expect(result.mismatches).toHaveLength(0);
    expect(seeds.update).not.toHaveBeenCalled();
  });

  it("silently skips seeds that no longer exist (not found error)", async () => {
    const { store, seeds } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: any[]) =>
      args[0] === "completed" ? [run] : []
    );
    seeds.show.mockRejectedValue(new Error("Issue not found: seed-abc"));

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set());

    expect(result.mismatches).toHaveLength(0);
    expect(result.errors).toHaveLength(0);
  });

  it("records error when seeds.show fails with unexpected error", async () => {
    const { store, seeds } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: any[]) =>
      args[0] === "completed" ? [run] : []
    );
    seeds.show.mockRejectedValue(new Error("Network connection error"));

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set());

    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("seed-abc");
  });

  it("records error when seeds.update fails, does not count as fixed", async () => {
    const { store, seeds } = makeMocks();
    const run = makeRun({ status: "completed" });
    store.getRunsByStatus.mockImplementation((...args: any[]) =>
      args[0] === "completed" ? [run] : []
    );
    seeds.show.mockResolvedValue({ status: "in_progress" });
    seeds.update.mockRejectedValue(new Error("Update failed"));

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set());

    expect(result.mismatches).toHaveLength(1);
    expect(result.fixed).toBe(0);
    expect(result.errors).toHaveLength(1);
    expect(result.errors[0]).toContain("seed-abc");
  });

  it("deduplicates multiple runs for same seed, uses most recent", async () => {
    const { store, seeds } = makeMocks();
    const olderRun = makeRun({
      id: "run-old",
      seed_id: "seed-shared",
      status: "completed",
      created_at: "2026-01-01T00:00:00.000Z",
    });
    const newerRun = makeRun({
      id: "run-new",
      seed_id: "seed-shared",
      status: "merged",
      created_at: "2026-01-02T00:00:00.000Z",
    });
    store.getRunsByStatus.mockImplementation((...args: any[]) => {
      if (args[0] === "completed") return [olderRun];
      if (args[0] === "merged") return [newerRun];
      return [];
    });
    seeds.show.mockResolvedValue({ status: "in_progress" });

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set());

    // Should only check once (deduplicated by seed_id)
    expect(seeds.show).toHaveBeenCalledTimes(1);
    // Should use the newer run's status (merged → closed)
    expect(result.mismatches[0].expectedSeedStatus).toBe("closed");
    expect(result.mismatches[0].runStatus).toBe("merged");
  });

  it("handles multiple seeds with different mismatch states", async () => {
    const { store, seeds } = makeMocks();
    const run1 = makeRun({ id: "run-1", seed_id: "seed-a", status: "completed" });
    const run2 = makeRun({ id: "run-2", seed_id: "seed-b", status: "conflict" });
    store.getRunsByStatus.mockImplementation((...args: any[]) => {
      if (args[0] === "completed") return [run1];
      if (args[0] === "conflict") return [run2];
      return [];
    });
    seeds.show.mockImplementation(async (...args: any[]) => {
      if (args[0] === "seed-a") return { status: "in_progress" };
      if (args[0] === "seed-b") return { status: "in_progress" };
      return { status: "open" };
    });

    const result = await detectAndFixMismatches(store as any, seeds as any, "proj-1", new Set());

    expect(result.mismatches).toHaveLength(2);
    expect(result.fixed).toBe(2);
  });
});
