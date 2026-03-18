import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore, type Run } from "../../lib/store.js";

// ── Mock BeadsRustClient ───────────────────────────────────────────────

const mockShow = vi.fn();

vi.mock("../../lib/beads-rust.js", () => {
  class MockBeadsRustClient {
    show = mockShow;
  }
  return { BeadsRustClient: MockBeadsRustClient };
});

// ── Helpers ────────────────────────────────────────────────────────────

function makeBead(overrides: Partial<{
  id: string;
  title: string;
  status: string;
}> = {}) {
  return {
    id: overrides.id ?? "bd-test",
    title: overrides.title ?? "Test bead",
    status: overrides.status ?? "open",
    type: "task",
    priority: "P2",
    assignee: null,
    parent: null,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
    description: null,
    labels: [],
    estimate_minutes: null,
    dependencies: [],
    children: [],
  };
}

function createTestRun(
  store: ForemanStore,
  projectId: string,
  overrides: Partial<{
    seedId: string;
    status: Run["status"];
  }> = {},
): Run {
  const seedId = overrides.seedId ?? "bd-test";
  const run = store.createRun(projectId, seedId, "claude-sonnet-4-6", "/tmp/wt");
  if (overrides.status) {
    store.updateRun(run.id, { status: overrides.status });
  }
  return store.getRun(run.id)!;
}

// ── Test suite ─────────────────────────────────────────────────────────

describe("foreman purge-zombie-runs", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let projectId: string;
  let beadsClient: InstanceType<typeof import("../../lib/beads-rust.js").BeadsRustClient>;

  beforeEach(async () => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-purge-zombie-test-"));
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("test-project", tmpDir);
    projectId = project.id;

    mockShow.mockReset();

    const { BeadsRustClient } = await import("../../lib/beads-rust.js");
    beadsClient = new BeadsRustClient(tmpDir);
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  // ── No project registered ─────────────────────────────────────────────

  describe("missing project", () => {
    it("throws when no project is registered for the path", async () => {
      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");

      await expect(
        purgeZombieRunsAction({}, beadsClient, store, "/nonexistent/path"),
      ).rejects.toThrow("No project registered");
    });
  });

  // ── No failed runs ────────────────────────────────────────────────────

  describe("no failed runs", () => {
    it("reports nothing to purge when there are no failed runs", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      // Create a non-failed run to ensure it's untouched
      createTestRun(store, projectId, { seedId: "bd-open", status: "running" });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      const result = await purgeZombieRunsAction({}, beadsClient, store, tmpDir);

      expect(result.checked).toBe(0);
      expect(result.purged).toBe(0);
      expect(mockShow).not.toHaveBeenCalled();

      consoleSpy.mockRestore();
    });
  });

  // ── Purge: bead is closed ─────────────────────────────────────────────

  describe("closed bead", () => {
    it("deletes a failed run whose bead has status 'closed'", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ id: "bd-closed", status: "closed" }));
      const run = createTestRun(store, projectId, { seedId: "bd-closed", status: "failed" });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      const result = await purgeZombieRunsAction({}, beadsClient, store, tmpDir);

      expect(result.purged).toBe(1);
      expect(result.skipped).toBe(0);
      expect(result.errors).toBe(0);
      // Run should be gone from the DB
      expect(store.getRun(run.id)).toBeNull();

      consoleSpy.mockRestore();
    });

    it("deletes a failed run whose bead has status 'completed'", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ id: "bd-done", status: "completed" }));
      const run = createTestRun(store, projectId, { seedId: "bd-done", status: "failed" });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      const result = await purgeZombieRunsAction({}, beadsClient, store, tmpDir);

      expect(result.purged).toBe(1);
      expect(store.getRun(run.id)).toBeNull();

      consoleSpy.mockRestore();
    });
  });

  // ── Purge: bead not found (404) ───────────────────────────────────────

  describe("bead not found", () => {
    it("deletes a failed run when the bead returns a 404 error", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "warn").mockImplementation(() => {});

      mockShow.mockRejectedValue(new Error("404 not found"));
      const run = createTestRun(store, projectId, { seedId: "bd-gone", status: "failed" });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      const result = await purgeZombieRunsAction({}, beadsClient, store, tmpDir);

      expect(result.purged).toBe(1);
      expect(result.errors).toBe(0);
      expect(store.getRun(run.id)).toBeNull();

      consoleSpy.mockRestore();
    });

    it("deletes a failed run when the bead error says 'not found'", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockRejectedValue(new Error("no issue found with that id"));
      const run = createTestRun(store, projectId, { seedId: "bd-missing", status: "failed" });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      const result = await purgeZombieRunsAction({}, beadsClient, store, tmpDir);

      expect(result.purged).toBe(1);
      expect(store.getRun(run.id)).toBeNull();

      consoleSpy.mockRestore();
    });
  });

  // ── Skip: bead is still open ──────────────────────────────────────────

  describe("open bead", () => {
    it("skips a failed run whose bead is still open", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ id: "bd-open", status: "open" }));
      const run = createTestRun(store, projectId, { seedId: "bd-open", status: "failed" });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      const result = await purgeZombieRunsAction({}, beadsClient, store, tmpDir);

      expect(result.skipped).toBe(1);
      expect(result.purged).toBe(0);
      // Run must still exist
      expect(store.getRun(run.id)).not.toBeNull();

      consoleSpy.mockRestore();
    });

    it("skips a failed run whose bead is in_progress", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ id: "bd-wip", status: "in_progress" }));
      const run = createTestRun(store, projectId, { seedId: "bd-wip", status: "failed" });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      const result = await purgeZombieRunsAction({}, beadsClient, store, tmpDir);

      expect(result.skipped).toBe(1);
      expect(store.getRun(run.id)).not.toBeNull();

      consoleSpy.mockRestore();
    });
  });

  // ── Error handling ────────────────────────────────────────────────────

  describe("unexpected bead lookup error", () => {
    it("counts unexpected errors and skips the run (does not delete)", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const consoleWarnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

      mockShow.mockRejectedValue(new Error("network timeout"));
      const run = createTestRun(store, projectId, { seedId: "bd-err", status: "failed" });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      const result = await purgeZombieRunsAction({}, beadsClient, store, tmpDir);

      expect(result.errors).toBe(1);
      expect(result.purged).toBe(0);
      expect(store.getRun(run.id)).not.toBeNull();

      consoleSpy.mockRestore();
      consoleWarnSpy.mockRestore();
    });
  });

  // ── Mixed scenario ────────────────────────────────────────────────────

  describe("mixed runs", () => {
    it("correctly handles a mix of purge, skip, and error in one pass", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "warn").mockImplementation(() => {});

      // Create 3 failed runs for different beads
      const runClosed = createTestRun(store, projectId, { seedId: "bd-closed", status: "failed" });
      const runOpen = createTestRun(store, projectId, { seedId: "bd-open", status: "failed" });
      const runErr = createTestRun(store, projectId, { seedId: "bd-err", status: "failed" });

      mockShow.mockImplementation(async (id: string) => {
        if (id === "bd-closed") return makeBead({ id, status: "closed" });
        if (id === "bd-open") return makeBead({ id, status: "open" });
        throw new Error("network timeout");
      });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      const result = await purgeZombieRunsAction({}, beadsClient, store, tmpDir);

      expect(result.checked).toBe(3);
      expect(result.purged).toBe(1);
      expect(result.skipped).toBe(1);
      expect(result.errors).toBe(1);

      expect(store.getRun(runClosed.id)).toBeNull();
      expect(store.getRun(runOpen.id)).not.toBeNull();
      expect(store.getRun(runErr.id)).not.toBeNull();

      consoleSpy.mockRestore();
    });
  });

  // ── --dry-run mode ────────────────────────────────────────────────────

  describe("--dry-run mode", () => {
    it("does not delete runs in dry-run mode", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ id: "bd-closed", status: "closed" }));
      const run = createTestRun(store, projectId, { seedId: "bd-closed", status: "failed" });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      const result = await purgeZombieRunsAction(
        { dryRun: true },
        beadsClient,
        store,
        tmpDir,
      );

      // Reports as purged (would be purged), but DB is untouched
      expect(result.purged).toBe(1);
      expect(store.getRun(run.id)).not.toBeNull();

      consoleSpy.mockRestore();
    });

    it("prints 'dry run' notice", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      mockShow.mockResolvedValue(makeBead({ status: "open" }));
      createTestRun(store, projectId, { seedId: "bd-open", status: "failed" });

      const { purgeZombieRunsAction } = await import("../commands/purge-zombie-runs.js");
      await purgeZombieRunsAction({ dryRun: true }, beadsClient, store, tmpDir);

      const output = consoleSpy.mock.calls.map((c) => String(c[0])).join("\n");
      expect(output).toContain("dry run");

      consoleSpy.mockRestore();
    });
  });

  // ── store.deleteRun ───────────────────────────────────────────────────

  describe("ForemanStore.deleteRun", () => {
    it("returns true when the run exists and is deleted", () => {
      const run = createTestRun(store, projectId, { seedId: "bd-x", status: "failed" });
      expect(store.deleteRun(run.id)).toBe(true);
      expect(store.getRun(run.id)).toBeNull();
    });

    it("returns false when the run does not exist", () => {
      expect(store.deleteRun("nonexistent-id")).toBe(false);
    });

    it("only deletes the targeted run, leaving others intact", () => {
      const run1 = createTestRun(store, projectId, { seedId: "bd-1", status: "failed" });
      const run2 = createTestRun(store, projectId, { seedId: "bd-2", status: "failed" });

      store.deleteRun(run1.id);

      expect(store.getRun(run1.id)).toBeNull();
      expect(store.getRun(run2.id)).not.toBeNull();
    });
  });
});
