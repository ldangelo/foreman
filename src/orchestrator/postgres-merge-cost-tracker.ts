import { query } from "../lib/db/pool-manager.js";
import type { CostStats, SessionCostSummary } from "./merge-cost-tracker.js";

type Period = "daily" | "weekly" | "monthly" | "all";

function periodCutoff(period: Period): string | null {
  if (period === "all") return null;
  const now = new Date();
  switch (period) {
    case "daily": {
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

export class PostgresMergeCostTracker {
  constructor(private readonly projectId: string) {}

  async getStats(period: Period = "all"): Promise<CostStats> {
    const cutoff = periodCutoff(period);
    const whereClause = cutoff ? "WHERE project_id = $1 AND recorded_at >= $2" : "WHERE project_id = $1";
    const params = cutoff ? [this.projectId, cutoff] : [this.projectId];

    const [totals] = await query<{
      totalcostusd: number;
      totalinputtokens: number;
      totaloutputtokens: number;
      entrycount: number;
    }>(
      `SELECT
         COALESCE(SUM(actual_cost_usd), 0) AS totalCostUsd,
         COALESCE(SUM(input_tokens), 0) AS totalInputTokens,
         COALESCE(SUM(output_tokens), 0) AS totalOutputTokens,
         COUNT(*) AS entryCount
       FROM merge_costs ${whereClause}`,
      params,
    );

    const tierRows = await query<{
      tier: number;
      count: number;
      totalcostusd: number;
      totalinputtokens: number;
      totaloutputtokens: number;
    }>(
      `SELECT
         tier,
         COUNT(*) AS count,
         COALESCE(SUM(actual_cost_usd), 0) AS totalCostUsd,
         COALESCE(SUM(input_tokens), 0) AS totalInputTokens,
         COALESCE(SUM(output_tokens), 0) AS totalOutputTokens
       FROM merge_costs ${whereClause}
       GROUP BY tier`,
      params,
    );

    const modelRows = await query<{
      model: string;
      count: number;
      totalcostusd: number;
      totalinputtokens: number;
      totaloutputtokens: number;
    }>(
      `SELECT
         model,
         COUNT(*) AS count,
         COALESCE(SUM(actual_cost_usd), 0) AS totalCostUsd,
         COALESCE(SUM(input_tokens), 0) AS totalInputTokens,
         COALESCE(SUM(output_tokens), 0) AS totalOutputTokens
       FROM merge_costs ${whereClause}
       GROUP BY model`,
      params,
    );

    return {
      totalCostUsd: Number(totals?.totalcostusd ?? 0),
      totalInputTokens: Number(totals?.totalinputtokens ?? 0),
      totalOutputTokens: Number(totals?.totaloutputtokens ?? 0),
      entryCount: Number(totals?.entrycount ?? 0),
      byTier: Object.fromEntries(tierRows.map((row) => [row.tier, {
        count: Number(row.count),
        totalCostUsd: Number(row.totalcostusd),
        totalInputTokens: Number(row.totalinputtokens),
        totalOutputTokens: Number(row.totaloutputtokens),
      }])),
      byModel: Object.fromEntries(modelRows.map((row) => [row.model, {
        count: Number(row.count),
        totalCostUsd: Number(row.totalcostusd),
        totalInputTokens: Number(row.totalinputtokens),
        totalOutputTokens: Number(row.totaloutputtokens),
      }])),
    };
  }

  async getSessionSummary(sessionId: string): Promise<SessionCostSummary> {
    const [row] = await query<{
      totalcostusd: number;
      totalinputtokens: number;
      totaloutputtokens: number;
      filecount: number;
    }>(
      `SELECT
         COALESCE(SUM(actual_cost_usd), 0) AS totalCostUsd,
         COALESCE(SUM(input_tokens), 0) AS totalInputTokens,
         COALESCE(SUM(output_tokens), 0) AS totalOutputTokens,
         COUNT(DISTINCT file_path) AS fileCount
       FROM merge_costs
       WHERE project_id = $1 AND session_id = $2`,
      [this.projectId, sessionId],
    );

    return {
      sessionId,
      totalCostUsd: Number(row?.totalcostusd ?? 0),
      totalInputTokens: Number(row?.totalinputtokens ?? 0),
      totalOutputTokens: Number(row?.totaloutputtokens ?? 0),
      fileCount: Number(row?.filecount ?? 0),
    };
  }

  async getResolutionRate(days = 30): Promise<{ successes: number; total: number; rate: number }> {
    const cutoff = new Date();
    cutoff.setDate(cutoff.getDate() - days);
    const [row] = await query<{ total: number }>(
      `SELECT COUNT(*) AS total FROM merge_costs WHERE project_id = $1 AND recorded_at >= $2`,
      [this.projectId, cutoff.toISOString()],
    );
    const total = Number(row?.total ?? 0);
    return { successes: total, total, rate: total === 0 ? 0 : 100 };
  }
}
