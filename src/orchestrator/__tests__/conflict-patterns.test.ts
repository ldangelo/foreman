import { describe, it, expect, beforeEach, afterEach } from "vitest";
import Database from "better-sqlite3";
import { ConflictPatterns } from "../conflict-patterns.js";

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

CREATE TABLE IF NOT EXISTS conflict_patterns (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  file_path TEXT NOT NULL,
  file_extension TEXT NOT NULL,
  tier INTEGER NOT NULL,
  success INTEGER NOT NULL,
  failure_reason TEXT,
  merge_queue_id INTEGER,
  seed_id TEXT,
  recorded_at TEXT NOT NULL,
  FOREIGN KEY (merge_queue_id) REFERENCES merge_queue(id)
);

CREATE INDEX IF NOT EXISTS idx_conflict_patterns_file ON conflict_patterns (file_extension, tier);
CREATE INDEX IF NOT EXISTS idx_conflict_patterns_merge ON conflict_patterns (merge_queue_id);
`;

function createTestDb(): Database.Database {
  const db = new Database(":memory:");
  db.pragma("journal_mode = WAL");
  db.pragma("foreign_keys = ON");
  db.exec(TEST_SCHEMA);
  return db;
}

describe("ConflictPatterns", () => {
  let db: Database.Database;
  let patterns: ConflictPatterns;

  beforeEach(() => {
    db = createTestDb();
    patterns = new ConflictPatterns(db);
  });

  afterEach(() => {
    db.close();
  });

  describe("recordOutcome", () => {
    it("should record a successful outcome", () => {
      patterns.recordOutcome("src/lib/store.ts", ".ts", 3, true);

      const rows = db.prepare("SELECT * FROM conflict_patterns").all() as Array<Record<string, unknown>>;
      expect(rows).toHaveLength(1);
      expect(rows[0].file_path).toBe("src/lib/store.ts");
      expect(rows[0].file_extension).toBe(".ts");
      expect(rows[0].tier).toBe(3);
      expect(rows[0].success).toBe(1);
      expect(rows[0].failure_reason).toBeNull();
      expect(rows[0].recorded_at).toBeTruthy();
    });

    it("should record a failed outcome with reason", () => {
      patterns.recordOutcome("src/index.ts", ".ts", 4, false, "Validation failed");

      const rows = db.prepare("SELECT * FROM conflict_patterns").all() as Array<Record<string, unknown>>;
      expect(rows).toHaveLength(1);
      expect(rows[0].success).toBe(0);
      expect(rows[0].failure_reason).toBe("Validation failed");
    });

    it("should record with optional merge_queue_id and seed_id", () => {
      // Insert a merge_queue row to satisfy FK constraint
      db.prepare(
        "INSERT INTO merge_queue (id, branch_name, seed_id, run_id, enqueued_at, status) VALUES (42, ?, ?, ?, ?, ?)",
      ).run("feature/test", "seed-123", "run-1", new Date().toISOString(), "pending");

      patterns.recordOutcome("src/app.ts", ".ts", 3, true, undefined, 42, "seed-123");

      const rows = db.prepare("SELECT * FROM conflict_patterns").all() as Array<Record<string, unknown>>;
      expect(rows).toHaveLength(1);
      expect(rows[0].merge_queue_id).toBe(42);
      expect(rows[0].seed_id).toBe("seed-123");
    });

    it("should record multiple outcomes", () => {
      patterns.recordOutcome("a.ts", ".ts", 3, true);
      patterns.recordOutcome("b.ts", ".ts", 3, false, "parse error");
      patterns.recordOutcome("c.js", ".js", 4, true);

      const rows = db.prepare("SELECT * FROM conflict_patterns").all() as Array<Record<string, unknown>>;
      expect(rows).toHaveLength(3);
    });
  });

  describe("shouldSkipTier", () => {
    it("should return false when no records exist", () => {
      expect(patterns.shouldSkipTier(".ts", 3)).toBe(false);
    });

    it("should return false with only 1 failure", () => {
      patterns.recordOutcome("a.ts", ".ts", 3, false, "fail");
      expect(patterns.shouldSkipTier(".ts", 3)).toBe(false);
    });

    it("should return true with >= 2 failures and 0 successes", () => {
      patterns.recordOutcome("a.ts", ".ts", 3, false, "fail1");
      patterns.recordOutcome("b.ts", ".ts", 3, false, "fail2");
      expect(patterns.shouldSkipTier(".ts", 3)).toBe(true);
    });

    it("should return false with >= 2 failures but also successes", () => {
      patterns.recordOutcome("a.ts", ".ts", 3, false, "fail1");
      patterns.recordOutcome("b.ts", ".ts", 3, false, "fail2");
      patterns.recordOutcome("c.ts", ".ts", 3, true);
      expect(patterns.shouldSkipTier(".ts", 3)).toBe(false);
    });

    it("should not cross-contaminate different extensions", () => {
      patterns.recordOutcome("a.js", ".js", 3, false, "fail1");
      patterns.recordOutcome("b.js", ".js", 3, false, "fail2");
      // .ts tier 3 should not be affected
      expect(patterns.shouldSkipTier(".ts", 3)).toBe(false);
      expect(patterns.shouldSkipTier(".js", 3)).toBe(true);
    });

    it("should not cross-contaminate different tiers", () => {
      patterns.recordOutcome("a.ts", ".ts", 3, false, "fail1");
      patterns.recordOutcome("b.ts", ".ts", 3, false, "fail2");
      // tier 4 should not be affected
      expect(patterns.shouldSkipTier(".ts", 4)).toBe(false);
      expect(patterns.shouldSkipTier(".ts", 3)).toBe(true);
    });
  });

  describe("getSuccessContext", () => {
    it("should return empty array when no successes exist", () => {
      expect(patterns.getSuccessContext(".ts", 3)).toEqual([]);
    });

    it("should return file paths of past successes", () => {
      patterns.recordOutcome("src/a.ts", ".ts", 3, true);
      patterns.recordOutcome("src/b.ts", ".ts", 3, true);
      patterns.recordOutcome("src/c.ts", ".ts", 3, false, "fail");

      const result = patterns.getSuccessContext(".ts", 3);
      expect(result).toHaveLength(2);
      expect(result).toContain("src/a.ts");
      expect(result).toContain("src/b.ts");
    });

    it("should only return successes for matching extension and tier", () => {
      patterns.recordOutcome("src/a.ts", ".ts", 3, true);
      patterns.recordOutcome("src/b.js", ".js", 3, true);
      patterns.recordOutcome("src/c.ts", ".ts", 4, true);

      const result = patterns.getSuccessContext(".ts", 3);
      expect(result).toEqual(["src/a.ts"]);
    });
  });

  describe("recordTestFailure", () => {
    it("should record test failure for all AI-resolved files", () => {
      // Insert a merge_queue row to satisfy FK constraint
      db.prepare(
        "INSERT INTO merge_queue (id, branch_name, seed_id, run_id, enqueued_at, status) VALUES (42, ?, ?, ?, ?, ?)",
      ).run("feature/test", "seed-1", "run-1", new Date().toISOString(), "pending");

      patterns.recordTestFailure(["src/a.ts", "src/b.js"], 42);

      const rows = db.prepare("SELECT * FROM conflict_patterns").all() as Array<Record<string, unknown>>;
      expect(rows).toHaveLength(2);

      for (const row of rows) {
        expect(row.success).toBe(0);
        expect(row.failure_reason).toBe("post_merge_test_failure");
        expect(row.tier).toBe(0); // tier 0 = test failure record
      }
    });

    it("should correctly extract file extensions", () => {
      patterns.recordTestFailure(["src/a.ts", "src/b.js", "config.json"]);

      const rows = db.prepare("SELECT * FROM conflict_patterns ORDER BY file_path").all() as Array<Record<string, unknown>>;
      expect(rows[0].file_extension).toBe(".json");
      expect(rows[1].file_extension).toBe(".ts");
      expect(rows[2].file_extension).toBe(".js");
    });

    it("should handle empty file list", () => {
      patterns.recordTestFailure([]);

      const rows = db.prepare("SELECT * FROM conflict_patterns").all() as Array<Record<string, unknown>>;
      expect(rows).toHaveLength(0);
    });
  });

  describe("shouldPreferFallback", () => {
    it("should return false when no records exist", () => {
      expect(patterns.shouldPreferFallback("src/a.ts")).toBe(false);
    });

    it("should return false with only 1 test failure", () => {
      patterns.recordTestFailure(["src/a.ts"]);
      expect(patterns.shouldPreferFallback("src/a.ts")).toBe(false);
    });

    it("should return true with >= 2 test failure records", () => {
      patterns.recordTestFailure(["src/a.ts"]);
      patterns.recordTestFailure(["src/a.ts"]);
      expect(patterns.shouldPreferFallback("src/a.ts")).toBe(true);
    });

    it("should not cross-contaminate different files", () => {
      patterns.recordTestFailure(["src/a.ts"]);
      patterns.recordTestFailure(["src/a.ts"]);
      expect(patterns.shouldPreferFallback("src/b.ts")).toBe(false);
    });
  });
});
