import { describe, it, expect, beforeEach, afterEach } from "vitest";
import Database from "better-sqlite3";
import { MergeCostTracker } from "../merge-cost-tracker.js";
import type { CostStats, SessionCostSummary } from "../merge-cost-tracker.js";

// Minimal schema needed for tests
const TEST_SCHEMA = `
CREATE TABLE IF NOT EXISTS merge_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  branch_name TEXT NOT NULL,
  seed_id TEXT NOT NULL,
  run_id TEXT NOT NULL,
  operation TEXT NOT NULL DEFAULT 'auto_merge',
  agent_name TEXT,
  files_modified TEXT DEFAULT '[]',
  enqueued_at TEXT NOT NULL,
  started_at TEXT,
  completed_at TEXT,
  status TEXT DEFAULT 'pending',
  resolved_tier INTEGER,
  error TEXT
);

CREATE TABLE IF NOT EXISTS merge_costs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL,
  merge_queue_id INTEGER,
  file_path TEXT NOT NULL,
  tier INTEGER NOT NULL,
  model TEXT NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  estimated_cost_usd REAL NOT NULL,
  actual_cost_usd REAL NOT NULL,
  recorded_at TEXT NOT NULL,
  FOREIGN KEY (merge_queue_id) REFERENCES merge_queue(id)
);

CREATE INDEX IF NOT EXISTS idx_merge_costs_session ON merge_costs (session_id);
CREATE INDEX IF NOT EXISTS idx_merge_costs_date ON merge_costs (recorded_at);
`;

function createTestDb(): Database.Database {
  const db = new Database(":memory:");
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.exec(TEST_SCHEMA);
  return db;
}

describe("MergeCostTracker", () => {
  let db: Database.Database;
  let tracker: MergeCostTracker;

  beforeEach(() => {
    db = createTestDb();
    tracker = new MergeCostTracker(db);
  });

  afterEach(() => {
    db.close();
  });

  describe("recordCost", () => {
    it("should record a cost entry", () => {
      tracker.recordCost(
        "session-1",
        undefined,
        "src/a.ts",
        3,
        "claude-sonnet-4-6",
        1000,
        500,
        0.0045,
        0.004,
      );

      const rows = db.prepare("SELECT * FROM merge_costs").all() as Array<Record<string, unknown>>;
      expect(rows).toHaveLength(1);
      expect(rows[0].session_id).toBe("session-1");
      expect(rows[0].file_path).toBe("src/a.ts");
      expect(rows[0].tier).toBe(3);
      expect(rows[0].model).toBe("claude-sonnet-4-6");
      expect(rows[0].input_tokens).toBe(1000);
      expect(rows[0].output_tokens).toBe(500);
      expect(rows[0].estimated_cost_usd).toBeCloseTo(0.0045);
      expect(rows[0].actual_cost_usd).toBeCloseTo(0.004);
      expect(rows[0].recorded_at).toBeTruthy();
    });

    it("should record with merge_queue_id", () => {
      // First insert a merge_queue entry to satisfy FK
      db.prepare(
        "INSERT INTO merge_queue (branch_name, seed_id, run_id, enqueued_at, status) VALUES (?, ?, ?, ?, ?)",
      ).run("feature/test", "seed-1", "run-1", new Date().toISOString(), "pending");

      tracker.recordCost(
        "session-1",
        1,
        "src/a.ts",
        3,
        "claude-sonnet-4-6",
        1000,
        500,
        0.0045,
        0.004,
      );

      const rows = db.prepare("SELECT * FROM merge_costs").all() as Array<Record<string, unknown>>;
      expect(rows).toHaveLength(1);
      expect(rows[0].merge_queue_id).toBe(1);
    });

    it("should record multiple costs", () => {
      tracker.recordCost("s1", undefined, "a.ts", 3, "claude-sonnet-4-6", 100, 50, 0.001, 0.001);
      tracker.recordCost("s1", undefined, "b.ts", 4, "claude-opus-4-6", 200, 100, 0.01, 0.01);
      tracker.recordCost("s2", undefined, "c.ts", 3, "claude-sonnet-4-6", 300, 150, 0.002, 0.002);

      const rows = db.prepare("SELECT * FROM merge_costs").all() as Array<Record<string, unknown>>;
      expect(rows).toHaveLength(3);
    });
  });

  describe("getStats", () => {
    beforeEach(() => {
      // Record costs across different dates
      const now = new Date();
      const yesterday = new Date(now);
      yesterday.setDate(yesterday.getDate() - 1);
      const lastWeek = new Date(now);
      lastWeek.setDate(lastWeek.getDate() - 8);
      const lastMonth = new Date(now);
      lastMonth.setDate(lastMonth.getDate() - 35);

      // Insert costs with specific timestamps
      const stmt = db.prepare(
        `INSERT INTO merge_costs (session_id, file_path, tier, model, input_tokens, output_tokens, estimated_cost_usd, actual_cost_usd, recorded_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      );

      stmt.run("s1", "a.ts", 3, "claude-sonnet-4-6", 1000, 500, 0.01, 0.01, now.toISOString());
      stmt.run("s1", "b.ts", 4, "claude-opus-4-6", 2000, 1000, 0.05, 0.05, now.toISOString());
      stmt.run("s2", "c.ts", 3, "claude-sonnet-4-6", 500, 250, 0.005, 0.005, yesterday.toISOString());
      stmt.run("s3", "d.ts", 3, "claude-sonnet-4-6", 300, 150, 0.003, 0.003, lastWeek.toISOString());
      stmt.run("s4", "e.ts", 4, "claude-opus-4-6", 400, 200, 0.02, 0.02, lastMonth.toISOString());
    });

    it("should return all-time stats when period is 'all'", () => {
      const stats = tracker.getStats("all");
      expect(stats.totalCostUsd).toBeCloseTo(0.088);
      expect(stats.totalInputTokens).toBe(4200);
      expect(stats.totalOutputTokens).toBe(2100);
      expect(stats.entryCount).toBe(5);
    });

    it("should return daily stats", () => {
      const stats = tracker.getStats("daily");
      // Should only include today's entries
      expect(stats.entryCount).toBe(2);
      expect(stats.totalCostUsd).toBeCloseTo(0.06);
    });

    it("should return weekly stats", () => {
      const stats = tracker.getStats("weekly");
      // Should include today + yesterday (within 7 days), but not last week or last month
      expect(stats.entryCount).toBe(3);
    });

    it("should return monthly stats", () => {
      const stats = tracker.getStats("monthly");
      // Should include today + yesterday + last week (within 30 days), but not last month
      expect(stats.entryCount).toBe(4);
    });

    it("should include tier breakdown", () => {
      const stats = tracker.getStats("all");
      expect(stats.byTier).toBeDefined();
      expect(stats.byTier[3]).toBeDefined();
      expect(stats.byTier[4]).toBeDefined();
      expect(stats.byTier[3].count).toBe(3);
      expect(stats.byTier[4].count).toBe(2);
    });

    it("should include model breakdown", () => {
      const stats = tracker.getStats("all");
      expect(stats.byModel).toBeDefined();
      expect(stats.byModel["claude-sonnet-4-6"]).toBeDefined();
      expect(stats.byModel["claude-opus-4-6"]).toBeDefined();
    });

    it("should return empty stats when no records exist", () => {
      const emptyDb = createTestDb();
      const emptyTracker = new MergeCostTracker(emptyDb);
      const stats = emptyTracker.getStats("all");
      expect(stats.totalCostUsd).toBe(0);
      expect(stats.entryCount).toBe(0);
      emptyDb.close();
    });
  });

  describe("getSessionSummary", () => {
    it("should return summary for a specific session", () => {
      tracker.recordCost("s1", undefined, "a.ts", 3, "claude-sonnet-4-6", 1000, 500, 0.01, 0.01);
      tracker.recordCost("s1", undefined, "b.ts", 4, "claude-opus-4-6", 2000, 1000, 0.05, 0.05);
      tracker.recordCost("s2", undefined, "c.ts", 3, "claude-sonnet-4-6", 500, 250, 0.005, 0.005);

      const summary = tracker.getSessionSummary("s1");
      expect(summary.sessionId).toBe("s1");
      expect(summary.totalCostUsd).toBeCloseTo(0.06);
      expect(summary.totalInputTokens).toBe(3000);
      expect(summary.totalOutputTokens).toBe(1500);
      expect(summary.fileCount).toBe(2);
    });

    it("should return zero summary for non-existent session", () => {
      const summary = tracker.getSessionSummary("nonexistent");
      expect(summary.sessionId).toBe("nonexistent");
      expect(summary.totalCostUsd).toBe(0);
      expect(summary.fileCount).toBe(0);
    });
  });
});
