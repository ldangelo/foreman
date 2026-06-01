/**
 * JiraTriggerEvent — structured event emitted when a Jira status transition
 * triggers a Foreman workflow.
 *
 * This event is emitted via the Foreman event system (REQ-009) and includes
 * all metadata needed for observability, debugging, and audit trails.
 */

import type { JiraProjectConfig } from "../lib/project-config.js";
import type { JiraIssue } from "../daemon/jira-poller.js";

// ── Trigger source ─────────────────────────────────────────────────────────────

/** How the trigger was detected */
export type TriggerSource = "poll" | "webhook";

// ── Status transition ───────────────────────────────────────────────────────────

/** Represents a Jira status change */
export interface JiraStatusTransition {
  /** Previous status name (fromString) */
  from: string;
  /** New status name (toString) */
  to: string;
}

// ── Event schema ────────────────────────────────────────────────────────────────

/**
 * Structured event emitted when a Jira status transition triggers a workflow.
 *
 * Emitted to: Foreman event bus (TBD) + console log + sentinel dashboard
 */
export interface JiraTriggerEvent {
  /** Event type identifier */
  eventType: "jira:trigger";
  /** ISO 8601 timestamp when the transition was detected */
  timestamp: string;
  /** How the transition was detected */
  source: TriggerSource;
  /** Jira project key (e.g., "PROJ") */
  projectKey: string;
  /** Jira issue key (e.g., "PROJ-123") */
  issueKey: string;
  /** Human-readable issue summary */
  issueSummary: string;
  /** Jira issue type (e.g., "Task", "Epic") */
  issueType: string;
  /** Current status name */
  currentStatus: string;
  /** Detected status change */
  transition: JiraStatusTransition;
  /** Mapped Foreman workflow name */
  workflowName: string;
  /** Created task ID (if triggered) */
  taskId?: string;
  /** External ID used for uniqueness (jira:<issueKey>) */
  externalId: string;
  /** Whether the trigger was executed or skipped (debounced/already-triggered) */
  triggered: boolean;
  /** Reason for skip, if not triggered */
  skipReason?: "already_triggered" | "debounced" | "outside_start_status";
}

// ── Event emission ─────────────────────────────────────────────────────────────

/**
 * Emit a JiraTriggerEvent to all configured observers.
 *
 * Current observers:
 * - Console log (always)
 * - Foreman event bus (future)
 * - Sentinel dashboard via tRPC (future)
 */
export function emitJiraTriggerEvent(event: JiraTriggerEvent): void {
  // Always log to console for observability
  const logLevel = event.triggered ? "info" : "debug";
  const prefix = `[JiraTriggerEvent][${event.source}]`;

  if (logLevel === "info") {
    console.log(
      `${prefix} ${event.issueKey}: ${event.transition.from} → ${event.transition.to} → ${event.workflowName} (task: ${event.taskId ?? "none"})`,
    );
  } else {
    console.debug(
      `${prefix} ${event.issueKey}: SKIPPED (${event.skipReason})`,
    );
  }

  // TODO: Emit to Foreman event bus when implemented (TRD-028)
  // eventBus.emit("jira:trigger", event);
}