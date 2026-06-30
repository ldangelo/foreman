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
export declare class ConflictPatterns {
    private db;
    constructor(db: PatternDb);
    /**
     * Record the outcome of a conflict resolution attempt (fire-and-forget INSERT).
     */
    recordOutcome(filePath: string, extension: string, tier: number, success: boolean, failureReason?: string, mergeQueueId?: number, seedId?: string): void;
    /**
     * Return true if >= 2 failures AND 0 successes for that extension+tier.
     * Used to skip tiers that consistently fail for a given file type.
     */
    shouldSkipTier(extension: string, tier: number): boolean;
    /**
     * Return file paths of past successes for a given extension+tier.
     * Used as additional context for Tier 3/4 AI prompts.
     */
    getSuccessContext(extension: string, tier: number): string[];
    /**
     * Record post-merge test failure for all AI-resolved files (MQ-T066).
     * Uses tier=0 as a sentinel value to distinguish test failure records.
     */
    recordTestFailure(aiResolvedFiles: string[], mergeQueueId?: number): void;
    /**
     * Return true if a file has >= 2 post-merge test failure records (MQ-T066).
     * Used to prefer fallback over AI resolution for problematic files.
     */
    shouldPreferFallback(filePath: string): boolean;
}
export {};
//# sourceMappingURL=conflict-patterns.d.ts.map