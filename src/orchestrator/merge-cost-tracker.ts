import type Database from "better-sqlite3";

// ── Interfaces ──────────────────────────────────────────────────────────

export interface TierBreakdown {
  count: number;
  totalCostUsd: number;
  totalInputTokens: number;
  totalOutputTokens: number;
}

export interface ModelBreakdown {
  count: number;
  totalCostUsd: number;
  totalInputTokens: number;
  totalOutputTokens: number;
}

export interface CostStats {
  totalCostUsd: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  entryCount: number;
  byTier: Record<number, TierBreakdown>;
  byModel: Record<string, ModelBreakdown>;
}

export interface SessionCostSummary {
  sessionId: string;
  totalCostUsd: number;
  totalInputTokens: number;
  totalOutputTokens: number;
  fileCount: number;
}

// ── Period helpers ───────────────────────────────────────────────────────

type Period = "daily" | "weekly" | "monthly" | "all";

function periodCutoff(period: Period): string | null {
  if (period === "all") return null;

  const now = new Date();
  switch (period) {
    case "daily": {
      // Start of today (midnight UTC)
      const start = new Date(now);
      start.setUTCHours(0, 0, 0, 0);
      return start.toISOString();
    }
    case "weekly": {
      const cutoff = new Date(now);
      cutoff.setDate(cutoff.getDate() - 7);
      return cutoff.toISOString();
    }
    case "monthly": {
      const cutoff = new Date(now);
      cutoff.setDate(cutoff.getDate() - 30);
      return cutoff.toISOString();
    }
  }
}

// ── MergeCostTracker ────────────────────────────────────────────────────

/**
 * Cost tracking for merge conflict resolution (MQ-T070).
 *
 * Records per-file, per-tier cost data and provides aggregate queries
 * for stats display and budget monitoring.
 */
export class MergeCostTracker {
  private db: Database.Database;

  constructor(db: Database.Database) {
    this.db = db;
  }

  /**
   * Record a cost entry (fire-and-forget INSERT).
   */
  recordCost(
    sessionId: string,
    mergeQueueId: number | undefined,
    filePath: string,
    tier: number,
    model: string,
    inputTokens: number,
    outputTokens: number,
    estimatedCostUsd: number,
    actualCostUsd: number,
  ): void {
    this.db
      .prepare(
        `INSERT INTO merge_costs
           (session_id, merge_queue_id, file_path, tier, model,
            input_tokens, output_tokens, estimated_cost_usd, actual_cost_usd, recorded_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(
        sessionId,
        mergeQueueId ?? null,
        filePath,
        tier,
        model,
        inputTokens,
        outputTokens,
        estimatedCostUsd,
        actualCostUsd,
        new Date().toISOString(),
      );
  }

  /**
   * Get aggregate cost statistics for a given time period.
   */
  getStats(period: Period = "all"): CostStats {
    const cutoff = periodCutoff(period);
    const whereClause = cutoff ? "WHERE recorded_at >= ?" : "";
    const params = cutoff ? [cutoff] : [];

    // Total aggregates
    const totals = this.db
      .prepare(
        `SELECT
           COALESCE(SUM(actual_cost_usd), 0) AS totalCostUsd,
           COALESCE(SUM(input_tokens), 0) AS totalInputTokens,
           COALESCE(SUM(output_tokens), 0) AS totalOutputTokens,
           COUNT(*) AS entryCount
         FROM merge_costs ${whereClause}`,
      )
      .get(...params) as {
      totalCostUsd: number;
      totalInputTokens: number;
      totalOutputTokens: number;
      entryCount: number;
    };

    // Tier breakdown
    const tierRows = this.db
      .prepare(
        `SELECT
           tier,
           COUNT(*) AS count,
           COALESCE(SUM(actual_cost_usd), 0) AS totalCostUsd,
           COALESCE(SUM(input_tokens), 0) AS totalInputTokens,
           COALESCE(SUM(output_tokens), 0) AS totalOutputTokens
         FROM merge_costs ${whereClause}
         GROUP BY tier`,
      )
      .all(...params) as Array<{
      tier: number;
      count: number;
      totalCostUsd: number;
      totalInputTokens: number;
      totalOutputTokens: number;
    }>;

    const byTier: Record<number, TierBreakdown> = {};
    for (const row of tierRows) {
      byTier[row.tier] = {
        count: row.count,
        totalCostUsd: row.totalCostUsd,
        totalInputTokens: row.totalInputTokens,
        totalOutputTokens: row.totalOutputTokens,
      };
    }

    // Model breakdown
    const modelRows = this.db
      .prepare(
        `SELECT
           model,
           COUNT(*) AS count,
           COALESCE(SUM(actual_cost_usd), 0) AS totalCostUsd,
           COALESCE(SUM(input_tokens), 0) AS totalInputTokens,
           COALESCE(SUM(output_tokens), 0) AS totalOutputTokens
         FROM merge_costs ${whereClause}
         GROUP BY model`,
      )
      .all(...params) as Array<{
      model: string;
      count: number;
      totalCostUsd: number;
      totalInputTokens: number;
      totalOutputTokens: number;
    }>;

    const byModel: Record<string, ModelBreakdown> = {};
    for (const row of modelRows) {
      byModel[row.model] = {
        count: row.count,
        totalCostUsd: row.totalCostUsd,
        totalInputTokens: row.totalInputTokens,
        totalOutputTokens: row.totalOutputTokens,
      };
    }

    return {
      totalCostUsd: totals.totalCostUsd,
      totalInputTokens: totals.totalInputTokens,
      totalOutputTokens: totals.totalOutputTokens,
      entryCount: totals.entryCount,
      byTier,
      byModel,
    };
  }

  /**
   * Get cost summary for a specific session.
   */
  getSessionSummary(sessionId: string): SessionCostSummary {
    const row = this.db
      .prepare(
        `SELECT
           COALESCE(SUM(actual_cost_usd), 0) AS totalCostUsd,
           COALESCE(SUM(input_tokens), 0) AS totalInputTokens,
           COALESCE(SUM(output_tokens), 0) AS totalOutputTokens,
           COUNT(DISTINCT file_path) AS fileCount
         FROM merge_costs
         WHERE session_id = ?`,
      )
      .get(sessionId) as {
      totalCostUsd: number;
      totalInputTokens: number;
      totalOutputTokens: number;
      fileCount: number;
    };

    return {
      sessionId,
      totalCostUsd: row.totalCostUsd,
      totalInputTokens: row.totalInputTokens,
      totalOutputTokens: row.totalOutputTokens,
      fileCount: row.fileCount,
    };
  }

  /**
   * Get AI resolution success rate over the last N days.
   * Returns { successes, total, rate } where rate is a percentage.
   */
  getResolutionRate(days: number = 30): { successes: number; total: number; rate: number } {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - days);

    // We count merge_queue entries that used AI resolution (resolved_tier >= 3)
    // This requires joining with merge_queue, but for simplicity we just count
    // merge_costs entries (each represents an AI attempt).
    // A better approach: count from conflict_patterns where tier >= 3.
    // For now, return based on merge_costs presence.
    const row = this.db
      .prepare(
        `SELECT COUNT(*) AS total FROM merge_costs WHERE recorded_at >= ?`,
      )
      .get(cutoff.toISOString()) as { total: number };

    // Count successful attempts from conflict_patterns if available
    let successes = 0;
    try {
      const successRow = this.db
        .prepare(
          `SELECT COUNT(*) AS cnt FROM conflict_patterns
           WHERE tier >= 3 AND success = 1 AND recorded_at >= ?`,
        )
        .get(cutoff.toISOString()) as { cnt: number } | undefined;
      successes = successRow?.cnt ?? 0;
    } catch {
      // conflict_patterns table may not exist yet
    }

    const total = row.total;
    const rate = total > 0 ? (successes / total) * 100 : 0;

    return { successes, total, rate };
  }
}
