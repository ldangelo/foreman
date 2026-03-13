// ── Merge Queue Error Codes ────────────────────────────────────────────
//
// Structured error codes for merge queue operations. Each code maps to a
// human-readable description used in event logging and diagnostics.

import type { EventType, ForemanStore } from "../lib/store.js";

export const MQ_ERRORS = {
  "MQ-001": "Queue entry not found",
  "MQ-002": "Syntax check failed",
  "MQ-003": "Prose detected in AI output",
  "MQ-004": "Conflict markers in AI output",
  "MQ-005": "Markdown fencing in AI output",
  "MQ-007": "Post-merge test failure",
  "MQ-008": "Stale pending entry (>24h)",
  "MQ-009": "Duplicate branch entries",
  "MQ-010": "Orphaned queue entry",
  "MQ-012": "Session budget exhausted",
  "MQ-013": "File exceeds size gate",
  "MQ-014": "Untracked file conflict",
  "MQ-015": "Tier skipped (pattern learning)",
  "MQ-016": "Fallback preferred (pattern learning)",
  "MQ-018": "All tiers exhausted, merge aborted",
  "MQ-019": "Seed preservation patch failed",
  "MQ-020": "Auto-commit state files failed",
} as const;

export type MQErrorCode = keyof typeof MQ_ERRORS;

// Merge-queue event types (subset of EventType)
type MergeQueueEventType = Extract<
  EventType,
  | "merge-queue-enqueue"
  | "merge-queue-dequeue"
  | "merge-queue-resolve"
  | "merge-queue-fallback"
>;

/**
 * Log a structured merge queue event to the store.
 *
 * If `details.errorCode` is a valid MQErrorCode, the corresponding
 * human-readable message is attached as `errorMessage`.
 */
export function logMergeEvent(
  store: ForemanStore,
  projectId: string,
  eventType: MergeQueueEventType,
  details: Record<string, unknown>,
  runId?: string,
): void {
  const enriched: Record<string, unknown> = {
    ...details,
    timestamp: new Date().toISOString(),
  };

  // Attach human-readable error message if an error code is present
  const errorCode = details.errorCode as string | undefined;
  if (errorCode && errorCode in MQ_ERRORS) {
    enriched.errorMessage = MQ_ERRORS[errorCode as MQErrorCode];
  }

  store.logEvent(projectId, eventType, enriched, runId);
}
