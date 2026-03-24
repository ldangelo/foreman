import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { utimesSync } from "node:fs";
import { ForemanStore, type Run } from "../../lib/store.js";
import { purgeLogsAction, type PurgeLogsOpts } from "../commands/purge-logs.js";

// ── Helpers ────────────────────────────────────────────────────────────

function makeUuid(): string {
  // Simple deterministic UUID-like string for testing
  const hex = () => Math.floor(Math.random() * 0xffff).toString(16).padStart(4, "0");
  return `${hex()}${hex()}-${hex()}-4${hex().slice(1)}-${hex()}-${hex()}${hex()}${hex()}`;
}

function createLogFiles(
  logsDir: string,
  runId: string,
  content: string = "log content",
  ageMs?: number,
): void {
  for (const ext of [".log", ".err", ".out"]) {
    const filePath = join(logsDir, `${runId}${ext}`);
    writeFileSync(filePath, content);
    if (ageMs !== undefined) {
      // Set mtime to simulate old files
      const mtime = new Date(Date.now() - ageMs);
      utimesSync(filePath, mtime, mtime);
    }
  }
}

function createTestRun(
  store: ForemanStore,
  projectId: string,
  overrides: {
    runId?: string;
    seedId?: string;
    status?: Run["status"];
  } = {},
): Run {
  const seedId = overrides.seedId ?? "bd-test";
  const run = store.createRun(projectId, seedId, "claude-sonnet-4-6", "/tmp/wt");
  const updates: Partial<Run> = {};
  if (overrides.status) updates.status = overrides.status;
  if (Object.keys(updates).length > 0) {
    store.updateRun(run.id, updates);
  }
  return store.getRun(run.id)!;
}

// ── Test suite ─────────────────────────────────────────────────────────

describe("foreman purge-logs", () => {
  let store: ForemanStore;
  let tmpDir: string;
  let logsDir: string;
  let projectId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-purge-logs-test-"));
    logsDir = join(tmpDir, "logs");
    mkdirSync(logsDir, { recursive: true });
    store = new ForemanStore(join(tmpDir, "test.db"));
    const project = store.registerProject("test-project", tmpDir);
    projectId = project.id;
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  // ── Empty logs directory ──────────────────────────────────────────────

  describe("empty logs directory", () => {
    it("returns zero counts when no files exist", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      expect(result.checked).toBe(0);
      expect(result.deleted).toBe(0);
      expect(result.skipped).toBe(0);
      expect(result.errors).toBe(0);
      expect(result.freedBytes).toBe(0);

      consoleSpy.mockRestore();
    });

    it("handles missing logs directory gracefully", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const result = await purgeLogsAction({ days: 7 }, store, "/nonexistent/logs/dir");

      expect(result.checked).toBe(0);
      expect(result.deleted).toBe(0);

      consoleSpy.mockRestore();
    });
  });

  // ── Age-based filtering ───────────────────────────────────────────────

  describe("age-based filtering", () => {
    it("deletes old orphaned logs (no run in DB, older than days)", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const runId = makeUuid();
      const eightDaysMs = 8 * 24 * 60 * 60 * 1000;

      createLogFiles(logsDir, runId, "old log", eightDaysMs);

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      expect(result.checked).toBe(1);
      expect(result.deleted).toBe(1);
      expect(result.skipped).toBe(0);
      expect(result.freedBytes).toBeGreaterThan(0);

      consoleSpy.mockRestore();
    });

    it("skips recent logs (newer than days)", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const runId = makeUuid();

      // File created just now — 0ms old
      createLogFiles(logsDir, runId, "recent log");

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      expect(result.checked).toBe(1);
      expect(result.deleted).toBe(0);
      expect(result.skipped).toBe(1);

      consoleSpy.mockRestore();
    });

    it("deletes old logs for terminal-status runs", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const run = createTestRun(store, projectId, { status: "completed" });
      const eightDaysMs = 8 * 24 * 60 * 60 * 1000;

      createLogFiles(logsDir, run.id, "completed log", eightDaysMs);

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      expect(result.deleted).toBe(1);

      consoleSpy.mockRestore();
    });

    it("deletes old logs for failed runs", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const run = createTestRun(store, projectId, { status: "failed" });
      const tenDaysMs = 10 * 24 * 60 * 60 * 1000;

      createLogFiles(logsDir, run.id, "failed log", tenDaysMs);

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      expect(result.deleted).toBe(1);

      consoleSpy.mockRestore();
    });

    it("deletes old logs for merged runs", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const run = createTestRun(store, projectId, { status: "merged" });
      const tenDaysMs = 10 * 24 * 60 * 60 * 1000;

      createLogFiles(logsDir, run.id, "merged log", tenDaysMs);

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      expect(result.deleted).toBe(1);

      consoleSpy.mockRestore();
    });
  });

  // ── Active runs are never deleted ─────────────────────────────────────

  describe("active run protection", () => {
    it("skips logs for running pipelines even if old", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const run = createTestRun(store, projectId, { status: "running" });
      const tenDaysMs = 10 * 24 * 60 * 60 * 1000;

      createLogFiles(logsDir, run.id, "running log", tenDaysMs);

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      expect(result.skipped).toBe(1);
      expect(result.deleted).toBe(0);

      consoleSpy.mockRestore();
    });

    it("skips logs for pending runs", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const run = createTestRun(store, projectId, { status: "pending" });
      const tenDaysMs = 10 * 24 * 60 * 60 * 1000;

      createLogFiles(logsDir, run.id, "pending log", tenDaysMs);

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      expect(result.skipped).toBe(1);
      expect(result.deleted).toBe(0);

      consoleSpy.mockRestore();
    });
  });

  // ── --dry-run mode ────────────────────────────────────────────────────

  describe("--dry-run mode", () => {
    it("does not delete files in dry-run mode", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const runId = makeUuid();
      const eightDaysMs = 8 * 24 * 60 * 60 * 1000;

      createLogFiles(logsDir, runId, "old log", eightDaysMs);

      const result = await purgeLogsAction({ days: 7, dryRun: true }, store, logsDir);

      // Should report as would-delete, but files should still exist
      expect(result.deleted).toBe(1);

      // Files should still be on disk
      const remaining = await import("node:fs/promises").then((m) =>
        m.readdir(logsDir),
      );
      expect(remaining.length).toBe(3); // .log + .err + .out

      consoleSpy.mockRestore();
    });

    it("prints dry-run notice in output", async () => {
      const calls: string[] = [];
      const consoleSpy = vi
        .spyOn(console, "log")
        .mockImplementation((msg: string) => calls.push(String(msg)));

      await purgeLogsAction({ days: 7, dryRun: true }, store, logsDir);

      const output = calls.join("\n");
      expect(output).toMatch(/dry run/i);

      consoleSpy.mockRestore();
    });
  });

  // ── --all flag ────────────────────────────────────────────────────────

  describe("--all flag", () => {
    it("deletes all terminal logs regardless of age", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      // One very recent orphaned log (would normally be kept)
      const runId = makeUuid();
      createLogFiles(logsDir, runId, "recent log"); // 0ms old

      // One recent failed run log
      const run = createTestRun(store, projectId, { status: "failed" });
      createLogFiles(logsDir, run.id, "recent failed log");

      const result = await purgeLogsAction({ all: true }, store, logsDir);

      expect(result.deleted).toBe(2);
      expect(result.skipped).toBe(0);

      consoleSpy.mockRestore();
    });

    it("still skips active runs with --all", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      const run = createTestRun(store, projectId, { status: "running" });
      createLogFiles(logsDir, run.id, "running log");

      const result = await purgeLogsAction({ all: true }, store, logsDir);

      expect(result.skipped).toBe(1);
      expect(result.deleted).toBe(0);

      consoleSpy.mockRestore();
    });
  });

  // ── Non-matching files are ignored ────────────────────────────────────

  describe("non-run files", () => {
    it("ignores files that don't match the UUID pattern", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});

      writeFileSync(join(logsDir, "README.txt"), "not a log");
      writeFileSync(join(logsDir, ".gitkeep"), "");

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      expect(result.checked).toBe(0);
      expect(result.deleted).toBe(0);

      consoleSpy.mockRestore();
    });
  });

  // ── Mixed scenario ────────────────────────────────────────────────────

  describe("mixed runs", () => {
    it("correctly handles mix of recent, old terminal, and active runs", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "warn").mockImplementation(() => {});

      const eightDaysMs = 8 * 24 * 60 * 60 * 1000;

      // Old failed run — should be deleted
      const oldFailed = createTestRun(store, projectId, { status: "failed" });
      createLogFiles(logsDir, oldFailed.id, "old failed", eightDaysMs);

      // Recent completed run — should be skipped (too new)
      const recentCompleted = createTestRun(store, projectId, { status: "completed" });
      createLogFiles(logsDir, recentCompleted.id, "recent completed"); // 0ms old

      // Old running run — should be skipped (active)
      const activeRun = createTestRun(store, projectId, { status: "running" });
      createLogFiles(logsDir, activeRun.id, "active", eightDaysMs);

      // Old orphaned log (not in DB) — should be deleted
      const orphanId = makeUuid();
      createLogFiles(logsDir, orphanId, "orphan", eightDaysMs);

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      expect(result.checked).toBe(4);
      expect(result.deleted).toBe(2);  // oldFailed + orphan
      expect(result.skipped).toBe(2);  // recentCompleted + activeRun
      expect(result.errors).toBe(0);

      consoleSpy.mockRestore();
    });
  });

  // ── freedBytes ────────────────────────────────────────────────────────

  describe("freed bytes accounting", () => {
    it("reports correct freed bytes for deleted files", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const eightDaysMs = 8 * 24 * 60 * 60 * 1000;
      const content = "x".repeat(100); // 100 bytes per file

      const runId = makeUuid();
      createLogFiles(logsDir, runId, content, eightDaysMs);

      const result = await purgeLogsAction({ days: 7 }, store, logsDir);

      // 3 files × 100 bytes each = 300 bytes
      expect(result.freedBytes).toBe(300);

      consoleSpy.mockRestore();
    });

    it("reports zero freed bytes in dry-run mode (would-free tracking)", async () => {
      const consoleSpy = vi.spyOn(console, "log").mockImplementation(() => {});
      const eightDaysMs = 8 * 24 * 60 * 60 * 1000;
      const content = "x".repeat(100);

      const runId = makeUuid();
      createLogFiles(logsDir, runId, content, eightDaysMs);

      const result = await purgeLogsAction({ days: 7, dryRun: true }, store, logsDir);

      // In dry-run mode, we still track how much WOULD be freed
      expect(result.freedBytes).toBe(300);

      consoleSpy.mockRestore();
    });
  });
});
