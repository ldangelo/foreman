import type { EventType, ForemanStore } from "../lib/store.js";
export declare const MQ_ERRORS: {
    readonly "MQ-001": "Queue entry not found";
    readonly "MQ-002": "Syntax check failed";
    readonly "MQ-003": "Prose detected in AI output";
    readonly "MQ-004": "Conflict markers in AI output";
    readonly "MQ-005": "Markdown fencing in AI output";
    readonly "MQ-007": "Post-merge test failure";
    readonly "MQ-008": "Stale pending entry (>24h)";
    readonly "MQ-009": "Duplicate branch entries";
    readonly "MQ-010": "Orphaned queue entry";
    readonly "MQ-012": "Session budget exhausted";
    readonly "MQ-013": "File exceeds size gate";
    readonly "MQ-014": "Untracked file conflict";
    readonly "MQ-015": "Tier skipped (pattern learning)";
    readonly "MQ-016": "Fallback preferred (pattern learning)";
    readonly "MQ-018": "All tiers exhausted, merge aborted";
    readonly "MQ-019": "Seed preservation patch failed";
    readonly "MQ-020": "Auto-commit state files failed";
};
export type MQErrorCode = keyof typeof MQ_ERRORS;
type MergeQueueEventType = Extract<EventType, "merge-queue-enqueue" | "merge-queue-dequeue" | "merge-queue-resolve" | "merge-queue-fallback">;
/**
 * Log a structured merge queue event to the store.
 *
 * If `details.errorCode` is a valid MQErrorCode, the corresponding
 * human-readable message is attached as `errorMessage`.
 */
export declare function logMergeEvent(store: ForemanStore, projectId: string, eventType: MergeQueueEventType, details: Record<string, unknown>, runId?: string): void;
export {};
//# sourceMappingURL=merge-error-codes.d.ts.map