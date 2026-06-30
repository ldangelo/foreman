export interface BvRecommendation {
    id: string;
    title: string;
    score: number;
    action?: string;
    reasons?: string[];
}
export interface BvTriageResult {
    recommendations: BvRecommendation[];
    quick_ref?: {
        actionable_count: number;
        top_picks: BvRecommendation[];
    };
}
export interface BvNextResult {
    id: string;
    title: string;
    score: number;
    claim_command?: string;
}
export interface BvClientOptions {
    /** Maximum milliseconds to wait for any bv invocation. Default: 10 000. */
    timeoutMs?: number;
}
/**
 * ADR-002: BvClient exposes ONLY typed robot-* methods.
 * There is NO public exec/run/execBv method — this enforces at the TypeScript
 * level that bare `bv` invocations (which open an interactive TUI) can never
 * happen from application code.
 *
 * ADR-003: Every method returns null on ANY failure (binary missing, timeout,
 * non-zero exit, parse error).  It never throws.
 */
export declare class BvClient {
    private readonly projectPath;
    private readonly timeoutMs;
    private errorLogged;
    constructor(projectPath: string, opts?: BvClientOptions);
    /** Returns the single highest-priority actionable task. */
    robotNext(): Promise<BvNextResult | null>;
    /** Returns full triage output with recommendations and quick_ref. */
    robotTriage(): Promise<BvTriageResult | null>;
    /** Returns parallel execution plan tracks. */
    robotPlan(): Promise<unknown | null>;
    /** Returns full graph metrics (PageRank, betweenness, HITS, etc.). */
    robotInsights(): Promise<unknown | null>;
    /** Returns stale issues, blocking cascades, and priority mismatches. */
    robotAlerts(): Promise<unknown | null>;
    /**
     * Core execution method.  Prefixed `_execBv` so it is easily identifiable
     * as private-by-convention (ADR-002: no public execBv surface).
     *
     * Steps:
     *   1. Run `br sync --flush-only` to ensure bv reads fresh data.
     *   2. Run `bv --robot-{flag} --format toon [extraArgs]` with timeout.
     *   3. Return raw stdout string, or null on any error.
     */
    private _execBv;
    /** Runs `br sync --flush-only` silently; failure is ignored. */
    private _runBrSync;
}
//# sourceMappingURL=bv.d.ts.map