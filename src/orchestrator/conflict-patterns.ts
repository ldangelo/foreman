import * as path from "node:path";

interface Statement<T = unknown> {
  get(...params: unknown[]): T;
  all(...params: unknown[]): T[];
  run(...params: unknown[]): unknown;
}

interface PatternDb {
  prepare(sql: string): Statement;
}

/**
 * Conflict Pattern Learning (MQ-T065/MQ-T066).
 *
 * Records outcomes of conflict resolution attempts and learns which
 * extension+tier combinations consistently fail, allowing the resolver
 * to skip doomed tiers and prefer fallback for problematic files.
 */
export class ConflictPatterns {
  private db: PatternDb;

  constructor(db: PatternDb) {
    this.db = db;
  }

  /**
   * Record the outcome of a conflict resolution attempt (fire-and-forget INSERT).
   */
  recordOutcome(
    filePath: string,
    extension: string,
    tier: number,
    success: boolean,
    failureReason?: string,
    mergeQueueId?: number,
    seedId?: string,
  ): void {
    this.db
      .prepare(
        `INSERT INTO conflict_patterns
           (file_path, file_extension, tier, success, failure_reason, merge_queue_id, seed_id, recorded_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        filePath,
        extension,
        tier,
        success ? 1 : 0,
        failureReason ?? null,
        mergeQueueId ?? null,
        seedId ?? null,
        new Date().toISOString(),
      );
  }

  /**
   * Return true if >= 2 failures AND 0 successes for that extension+tier.
   * Used to skip tiers that consistently fail for a given file type.
   */
  shouldSkipTier(extension: string, tier: number): boolean {
    const row = this.db
      .prepare(
        `SELECT
           COALESCE(SUM(CASE WHEN success = 0 THEN 1 ELSE 0 END), 0) AS failures,
           COALESCE(SUM(CASE WHEN success = 1 THEN 1 ELSE 0 END), 0) AS successes
         FROM conflict_patterns
         WHERE file_extension = ? AND tier = ?`,
      )
      .get(extension, tier) as { failures: number; successes: number } | undefined;

    if (!row) return false;
    return row.failures >= 2 && row.successes === 0;
  }

  /**
   * Return file paths of past successes for a given extension+tier.
   * Used as additional context for Tier 3/4 AI prompts.
   */
  getSuccessContext(extension: string, tier: number): string[] {
    const rows = this.db
      .prepare(
        `SELECT file_path FROM conflict_patterns
         WHERE file_extension = ? AND tier = ? AND success = 1`,
      )
      .all(extension, tier) as Array<{ file_path: string }>;

    return rows.map((r) => r.file_path);
  }

  /**
   * Record post-merge test failure for all AI-resolved files (MQ-T066).
   * Uses tier=0 as a sentinel value to distinguish test failure records.
   */
  recordTestFailure(
    aiResolvedFiles: string[],
    mergeQueueId?: number,
  ): void {
    const now = new Date().toISOString();
    const stmt = this.db.prepare(
      `INSERT INTO conflict_patterns
         (file_path, file_extension, tier, success, failure_reason, merge_queue_id, seed_id, recorded_at)
       VALUES (?, ?, 0, 0, 'post_merge_test_failure', ?, NULL, ?)`,
    );

    for (const filePath of aiResolvedFiles) {
      const ext = path.extname(filePath);
      stmt.run(filePath, ext, mergeQueueId ?? null, now);
    }
  }

  /**
   * Return true if a file has >= 2 post-merge test failure records (MQ-T066).
   * Used to prefer fallback over AI resolution for problematic files.
   */
  shouldPreferFallback(filePath: string): boolean {
    const row = this.db
      .prepare(
        `SELECT COUNT(*) AS cnt FROM conflict_patterns
         WHERE file_path = ? AND failure_reason = 'post_merge_test_failure'`,
      )
      .get(filePath) as { cnt: number } | undefined;

    return (row?.cnt ?? 0) >= 2;
  }
}
