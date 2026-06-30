/**
 * JiraTriggerEvent — structured event emitted when a Jira status transition
 * triggers a Foreman workflow.
 *
 * This event is emitted via the Foreman event system (REQ-009) and includes
 * all metadata needed for observability, debugging, and audit trails.
 */
/** How the trigger was detected */
export type TriggerSource = "poll" | "webhook";
/** Represents a Jira status change */
export interface JiraStatusTransition {
    /** Previous status name (fromString) */
    from: string;
    /** New status name (toString) */
    to: string;
}
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
/**
 * Emit a JiraTriggerEvent to all configured observers.
 *
 * Current observers:
 * - Console log (always)
 * - Foreman event bus (future)
 * - Sentinel dashboard via tRPC (future)
 */
export declare function emitJiraTriggerEvent(event: JiraTriggerEvent): void;
//# sourceMappingURL=jira-trigger-event.d.ts.map