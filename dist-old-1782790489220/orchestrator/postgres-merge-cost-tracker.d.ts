import type { CostStats, SessionCostSummary } from "./merge-cost-tracker.js";
type Period = "daily" | "weekly" | "monthly" | "all";
export declare class PostgresMergeCostTracker {
    private readonly projectId;
    constructor(projectId: string);
    getStats(period?: Period): Promise<CostStats>;
    getSessionSummary(sessionId: string): Promise<SessionCostSummary>;
    getResolutionRate(days?: number): Promise<{
        successes: number;
        total: number;
        rate: number;
    }>;
}
export {};
//# sourceMappingURL=postgres-merge-cost-tracker.d.ts.map