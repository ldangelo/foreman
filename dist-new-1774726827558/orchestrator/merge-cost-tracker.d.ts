import type Database from "better-sqlite3";
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
type Period = "daily" | "weekly" | "monthly" | "all";
/**
 * Cost tracking for merge conflict resolution (MQ-T070).
 *
 * Records per-file, per-tier cost data and provides aggregate queries
 * for stats display and budget monitoring.
 */
export declare class MergeCostTracker {
    private db;
    constructor(db: Database.Database);
    /**
     * Record a cost entry (fire-and-forget INSERT).
     */
    recordCost(sessionId: string, mergeQueueId: number | undefined, filePath: string, tier: number, model: string, inputTokens: number, outputTokens: number, estimatedCostUsd: number, actualCostUsd: number): void;
    /**
     * Get aggregate cost statistics for a given time period.
     */
    getStats(period?: Period): CostStats;
    /**
     * Get cost summary for a specific session.
     */
    getSessionSummary(sessionId: string): SessionCostSummary;
    /**
     * Get AI resolution success rate over the last N days.
     * Returns { successes, total, rate } where rate is a percentage.
     */
    getResolutionRate(days?: number): {
        successes: number;
        total: number;
        rate: number;
    };
}
export {};
//# sourceMappingURL=merge-cost-tracker.d.ts.map